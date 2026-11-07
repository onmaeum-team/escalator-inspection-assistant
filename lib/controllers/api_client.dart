import 'dart:convert'; // jsonDecode / jsonEncode / utf8 (서버 JSON 읽고 쓰기)
import 'dart:typed_data'; // Uint8List (녹음한 WAV 바이트)

import 'package:http/http.dart' as http; // HTTP 요청 패키지

import '../models/equipment.dart'; // 설비, 점검 이력 모델
import '../models/inspection_session.dart'; // 점검 세션, 음성 처리 결과 모델

/// 서버 설정
class ApiConfig {
  ApiConfig._(); // 객체를 만들 필요 없는 설정 모음이라 생성자를 숨김

  /// 백엔드가 준비되면 true 로. false 면 서버 호출 없이 온디바이스 DB만 사용.
  /// true 면 '음성으로 점검 시작'이 핸즈프리 점검 화면(서버 연동)으로 연결됨.
  static const bool useServer = true;

  /// 안드로이드 에뮬레이터에서 내 PC 의 localhost = 10.0.2.2
  /// 실제 폰: 노트북(가짜 보드) IP 또는 보드 핫스팟 IP. 예) http://192.168.0.10:8080
  static const String baseUrl = 'http://10.0.2.2:8080';

  static const Duration timeout = Duration(seconds: 5); // 일반 요청은 5초 안에 답이 없으면 끊김으로 봄

  /// 음성 1건 처리 (STT + LLM) 는 오래 걸리므로 따로
  static const Duration voiceTimeout = Duration(seconds: 15);
}

/// 서버가 4xx 로 거절한 경우. code 는 API 정의서의 에러 코드 (예: MISSING_REQUIRED_ITEMS)
class ApiError implements Exception {
  final int status; // HTTP 상태 코드 (404, 409 …)
  final String code; // 에러 코드 (예: NOTE_REQUIRED)
  final String message; // 사용자에게 보여 줄 문구
  ApiError(this.status, this.code, this.message); // 생성자
  @override
  String toString() => 'ApiError($status $code: $message)'; // 로그에 찍힐 모양
}

/// 404 — 서버에 없는 에스컬레이터
class ApiNotFound implements Exception {}

/// 서버 꺼짐 / 네트워크 없음 / 타임아웃 / 5xx → 온디바이스 데이터로 대체
class ApiOffline implements Exception {
  final Object cause; // 실패 원인
  ApiOffline(this.cause); // 생성자
  @override
  String toString() => 'ApiOffline($cause)'; // 로그에 찍힐 모양
}

/// API 명세서 (노션) 기준 — 프레임 1·2 담당분
///
/// | 화면            | Method | Endpoint                                   |
/// |-----------------|--------|--------------------------------------------|
/// | QR / NFC 스캔    | GET    | /api/escalators/{escalatorId}              |
/// | 최근 점검 이력    | GET    | /api/escalators/{escalatorId}/histories    |
/// | 점검 기록 / 설비 이력 | GET | /api/escalators/{escalatorId}/histories    |
///
/// ※ 명세서에 응답 JSON 형식이 아직 없어서 아래 형식을 가정함.
///   백엔드와 필드명이 다르면 models/equipment.dart 의 fromJson 만 고치면 됨.
///
/// GET /api/escalators/esc-3
/// {
///   "escalatorId": "esc-3",
///   "name": "3호기 에스컬레이터",
///   "location": "B동 2층"
/// }
///
/// GET /api/escalators/esc-3/histories
/// [
///   {
///     "inspectionId": "insp-101",
///     "inspectedAt": "2026-09-14T10:30:00",
///     "inspector": "김점검",
///     "durationMinutes": 12,
///     "status": "CAUTION",              // NORMAL | CAUTION
///     "checkedItems": ["핸드레일", "스텝체인"],
///     "cautionItems": ["스텝체인"],
///     "note": "스텝체인 장력 약간 느슨함"   // 특이사항 (선택)
///   }
/// ]
/// ( { "data": ... } 로 한 번 감싸서 와도 처리됨 )
class ApiClient {
  ApiClient._(); // 밖에서 새로 만들지 못하게 숨김
  static final instance = ApiClient._(); // 앱 전체에서 하나만 씀 (ApiClient.instance)

  final http.Client _http = http.Client(); // 실제로 요청을 보내는 HTTP 클라이언트

  Future<dynamic> _get(String path) async { // 설비·이력 조회용 GET (기존 코드)
    if (!ApiConfig.useServer) throw ApiOffline('useServer = false'); // 서버를 안 쓰는 설정이면 바로 오프라인 처리

    final res = await _http
        .get(Uri.parse('${ApiConfig.baseUrl}$path')) // 주소로 GET 요청
        .timeout(ApiConfig.timeout) // 5초 제한
        .catchError((Object e) => throw ApiOffline(e)); // 연결 실패, 타임아웃 등

    if (res.statusCode == 404) throw ApiNotFound(); // 없는 설비
    if (res.statusCode >= 400) throw ApiOffline('HTTP ${res.statusCode}'); // 그 밖의 오류는 오프라인처럼 처리

    final body = jsonDecode(utf8.decode(res.bodyBytes)); // 한글이 깨지지 않게 UTF-8로 읽고 JSON 해석
    return (body is Map && body.containsKey('data')) ? body['data'] : body; // {"data": ...} 로 감싸져 있으면 벗겨서 반환
  }

  /// QR / NFC 스캔, 설비 정보
  Future<Equipment> getEscalator(String escalatorId) async {
    final data =
        await _get('/api/escalators/${Uri.encodeComponent(escalatorId)}'); // 설비 번호를 주소에 넣어 요청
    return Equipment.fromJson(Map<String, dynamic>.from(data as Map)); // JSON → Equipment
  }

  /// 최근 점검 이력 / 점검 기록 / 설비 이력 (최신순으로 정렬해서 반환)
  Future<List<InspectionRecord>> getHistories(String escalatorId) async {
    final data = await _get(
        '/api/escalators/${Uri.encodeComponent(escalatorId)}/histories'); // 이력 요청
    final list = data is List ? data : (data as Map)['histories'] as List; // 목록이 바로 오든 {"histories": [...]} 로 오든 꺼냄
    final records = [
      for (final m in list)
        InspectionRecord.fromJson(Map<String, dynamic>.from(m as Map)), // 하나씩 InspectionRecord 로 변환
    ];
    records.sort((a, b) => b.date.compareTo(a.date)); // 최신순 정렬
    return records;
  }

  // ───────────── 점검 세션 (핸즈프리 음성 점검) ─────────────
  //
  // | 기능        | Method | Endpoint                                        |
  // |-------------|--------|-------------------------------------------------|
  // | 연결 확인    | GET    | /api/health                                     |
  // | 점검 시작    | POST   | /api/inspections                                |
  // | 말 한 덩어리 | POST   | /api/inspections/{id}/utterances (multipart)    |
  // | 취소        | POST   | /api/inspections/{id}/undo                      |
  // | 점검 끝     | POST   | /api/inspections/{id}/finish                    |
  // | 손 수정     | PATCH  | /api/inspections/{id}/items/{itemCode}          |
  // | 결과        | GET    | /api/inspections/{id}/result                    |
  // | 제출        | POST   | /api/inspections/{id}/submit                    |

  Uri _u(String path, [Map<String, String>? query]) => // 서버 주소 + 경로 (+ ?쿼리) 로 전체 주소 만들기
      Uri.parse('${ApiConfig.baseUrl}$path').replace(queryParameters: query);

  String _id(String s) => Uri.encodeComponent(s); // 주소에 넣을 값의 특수문자를 안전하게 바꿈 (예: 3.10 그대로, 공백 → %20)

  /// 네트워크 실패/타임아웃 → ApiOffline
  Future<http.Response> _req(Future<http.Response> Function() call, // 실제 요청을 보내는 함수를 받아서
      {Duration timeout = ApiConfig.timeout}) async { // 제한 시간 안에 실행
    if (!ApiConfig.useServer) throw ApiOffline('useServer = false'); // 서버를 안 쓰는 설정이면 바로 오프라인 처리
    try {
      return await call().timeout(timeout); // 요청 보내고 응답 기다리기
    } catch (e) {
      throw ApiOffline(e); // 연결 실패·시간 초과는 전부 오프라인으로
    }
  }

  /// 4xx/5xx → ApiError, 성공이면 { "data": ... } 를 풀어서 반환
  Map<String, dynamic> _decode(http.Response res) {
    final text = utf8.decode(res.bodyBytes); // 응답 본문을 UTF-8 글자로
    final body = text.isEmpty ? null : jsonDecode(text); // JSON 해석 (비어 있으면 null)
    if (res.statusCode >= 400) { // 서버가 거절했으면
      final d = body is Map ? (body['detail'] ?? body['error']) : null; // FastAPI 오류는 {"detail": {"code", "message"}} 모양
      throw ApiError(
        res.statusCode, // 상태 코드
        d is Map ? '${d['code'] ?? 'HTTP_${res.statusCode}'}' : 'HTTP_${res.statusCode}', // 에러 코드 (없으면 HTTP_409 같은 이름)
        d is Map ? '${d['message'] ?? ''}' : '${d ?? ''}', // 사용자 문구
      );
    }
    final data = (body is Map && body.containsKey('data')) ? body['data'] : body; // {"data": ...} 벗기기
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{'value': data}; // 항상 Map 으로 돌려줌
  }

  Future<Map<String, dynamic>> health() async => // 연결 확인
      _decode(await _req(() => _http.get(_u('/api/health'))));

  Future<InspectionSession> startInspection(String escalatorId, // 점검 시작
      {String inspector = '점검자'}) async {
    final res = await _req(() => _http.post(_u('/api/inspections'), // POST 요청
        body: {'escalatorId': escalatorId, 'inspector': inspector})); // 폼 값으로 설비 번호와 점검자 이름 전송
    return InspectionSession.fromJson(_decode(res)); // 점검 번호와 항목 목록
  }

  /// VAD 가 자른 말 한 덩어리 전송. [wav] = WAV 16kHz 모노.
  /// 테스트용으로 [text] 만 보내면 서버가 STT 를 건너뜀.
  Future<UtteranceResult> sendUtterance(String inspectionId, int clientSeq,
      {Uint8List? wav, String? text}) async {
    final req = http.MultipartRequest( // 파일을 보낼 수 있는 multipart 요청 만들기
        'POST', _u('/api/inspections/${_id(inspectionId)}/utterances'))
      ..fields['clientSeq'] = '$clientSeq'; // 발화 순번 (재전송 중복 방지)
    if (text != null) req.fields['text'] = text; // 테스트 문장이 있으면 함께
    if (wav != null) { // 녹음이 있으면
      req.files.add(http.MultipartFile.fromBytes('audio', wav, // 'audio' 라는 이름으로 WAV 파일 첨부
          filename: 'utt_$clientSeq.wav'));
    }
    final res = await _req(
        () async => http.Response.fromStream(await _http.send(req)), // 보내고 응답을 받아 일반 응답으로 변환
        timeout: ApiConfig.voiceTimeout); // 음성은 15초 제한
    return UtteranceResult.fromJson(_decode(res)); // 처리 결과 (recorded, question …)
  }

  Future<Map<String, dynamic>> undo(String inspectionId) async => _decode( // 마지막 기록 취소
      await _req(() => _http.post(_u('/api/inspections/${_id(inspectionId)}/undo'))));

  Future<UtteranceResult> finish(String inspectionId) async { // 점검 끝 → 빠진 항목 확인
    final data = _decode(await _req(
        () => _http.post(_u('/api/inspections/${_id(inspectionId)}/finish'))));
    return UtteranceResult.fromJson({'kind': 'command', 'command': 'finish', ...data}); // 음성 "점검 끝"과 같은 모양으로 맞춤
  }

  /// 화면 손 수정 (노션의 체크박스 + 결과 수정을 하나로)
  Future<SessionItem> editItem(String inspectionId, String itemCode,
      Map<String, dynamic> changes) async { // changes 예: {"status": "부적합", "note": "..."}
    final res = await _req(() => _http.patch( // PATCH 요청
          _u('/api/inspections/${_id(inspectionId)}/items/${_id(itemCode)}'),
          headers: {'Content-Type': 'application/json'}, // JSON 으로 보낸다고 알림
          body: jsonEncode(changes), // 바꿀 값을 JSON 글자로
        ));
    return SessionItem.fromJson(_decode(res)); // 고쳐진 항목
  }

  Future<InspectionResultData> result(String inspectionId) async => // 검토 화면용 전체 결과
      InspectionResultData.fromJson(_decode(await _req(
          () => _http.get(_u('/api/inspections/${_id(inspectionId)}/result')))));

  /// 미확인 항목이 있으면 409 MISSING_REQUIRED_ITEMS → 확인 후 [acknowledgeMissing] = true 로 다시
  Future<Map<String, dynamic>> submit(String inspectionId,
          {bool acknowledgeMissing = false}) async =>
      _decode(await _req(() => _http.post(_u(
          '/api/inspections/${_id(inspectionId)}/submit',
          {'acknowledgeMissing': '$acknowledgeMissing'})))); // 주소 뒤에 ?acknowledgeMissing=true/false
}
