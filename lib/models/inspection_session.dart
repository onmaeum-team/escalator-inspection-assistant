/// 보드 FastAPI 서버(/api/inspections/...)와 주고받는 점검 세션 모델.
/// 판정은 정기검사기준 그대로: 적합 / 부적합 / 해당없음 / 미확인
library;

Map<String, dynamic> _map(dynamic v) => // 서버 JSON 값을 Map으로 바꾸는 도우미
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{}; // Map이 아니면 빈 Map

/// 검사기준 항목 1개의 이번 점검 결과
class SessionItem {
  final String itemCode; // 예: 3.10
  final String itemName; // 예: 승강기부품의 상태
  final String status; // 적합 | 부적합 | 해당없음 | 미확인
  final String? location; // 상부 | 하부 | 양쪽
  final String? note; // 특기사항
  final String? action; // 현장조치완료 | 조치필요
  final List<String> detail; // 세부 항목
  final String? criteria; // 규칙 엔진이 판정에 쓴 기준

  const SessionItem({ // 생성자
    required this.itemCode,
    required this.itemName,
    required this.status,
    this.location,
    this.note,
    this.action,
    this.detail = const [],
    this.criteria,
  });

  bool get isDone => status != '미확인'; // 기록이 끝난 항목이면 true

  factory SessionItem.fromJson(Map<String, dynamic> j) => SessionItem( // 서버 JSON → SessionItem
        itemCode: '${j['itemCode'] ?? ''}', // 검사기준 번호
        itemName: '${j['itemName'] ?? j['name'] ?? ''}', // 항목 이름 (itemName 이 없으면 name)
        status: '${j['status'] ?? '미확인'}', // 판정 (없으면 미확인)
        location: j['location'] as String?, // 위치
        note: j['note'] as String?, // 특기사항
        action: j['action'] as String?, // 조치
        detail: List<String>.from(j['detail'] ?? const []), // 세부 항목 목록 (없으면 빈 목록)
        criteria: j['criteria'] as String?, // 판정 기준
      );
}

/// 서버가 돌려주는 안내 문구 (audioId 가 있으면 보드 TTS 음성이 있음)
class Speech {
  final String text; // 안내 문장
  final String? audioId; // 보드 TTS 음성 파일 id (아직은 null)
  const Speech(this.text, this.audioId);

  static Speech? fromJson(dynamic j) { // 서버 JSON → Speech
    if (j is! Map || j['text'] == null) return null; // 안내가 없으면 null
    return Speech('${j['text']}', j['audioId']?.toString());
  }
}

/// POST /api/inspections → 점검 시작
class InspectionSession {
  final String inspectionId; // 점검 번호 (이후 모든 요청에 씀)
  final List<SessionItem> items; // 이번 점검 대상 항목들 (전부 미확인으로 시작)
  const InspectionSession(this.inspectionId, this.items);

  factory InspectionSession.fromJson(Map<String, dynamic> j) => InspectionSession( // 서버 JSON → 점검 세션
        '${j['inspectionId']}', // 점검 번호
        [for (final m in (j['items'] as List? ?? const [])) SessionItem.fromJson(_map(m))], // 항목 목록을 하나씩 변환
      );
}

/// POST /api/inspections/{id}/utterances → 말 한 덩어리 처리 결과
///
/// kind: recorded(기록) · question(추가 질문) · answered(질문에 대답)
///       command(취소·남은 개수·점검 끝 등) · ignored(무관한 말) · retry(다시 말하기)
class UtteranceResult {
  final String kind; // 처리 결과 종류 (위 설명)
  final String? command; // undo | progress | finish | repeat | skip
  final String? transcript; // 받아쓴 문장
  final SessionItem? item; // 기록되거나 바뀐 항목
  final Speech? speech; // 안내 문구
  final int recorded; // 기록한 항목 수
  final int total; // 전체 항목 수
  final List<SessionItem> missing; // command == finish 일 때

  const UtteranceResult({ // 생성자
    required this.kind,
    this.command,
    this.transcript,
    this.item,
    this.speech,
    this.recorded = 0,
    this.total = 0,
    this.missing = const [],
  });

  factory UtteranceResult.fromJson(Map<String, dynamic> j) { // 서버 JSON → 처리 결과
    final p = _map(j['progress']); // 진행률 부분
    return UtteranceResult(
      kind: '${j['kind']}', // 종류
      command: j['command'] as String?, // 명령 이름
      transcript: j['transcript'] as String?, // 받아쓴 문장
      item: j['item'] is Map ? SessionItem.fromJson(_map(j['item'])) : null, // 항목이 있으면 변환
      speech: Speech.fromJson(j['speech']), // 안내 문구
      recorded: (p['recorded'] as num?)?.toInt() ?? 0, // 기록한 수
      total: (p['total'] as num?)?.toInt() ?? 0, // 전체 수
      missing: [for (final m in (j['missing'] as List? ?? const [])) SessionItem.fromJson(_map(m))], // 빠진 항목 목록
    );
  }
}

/// GET /api/inspections/{id}/result → 검토 화면
class InspectionResultData {
  final Map<String, int> summary; // 적합·부적합·해당없음·미확인 개수
  final List<SessionItem> items; // 전체 항목 결과
  final bool submitted; // 제출했는지
  const InspectionResultData(this.summary, this.items, this.submitted);

  factory InspectionResultData.fromJson(Map<String, dynamic> j) => InspectionResultData( // 서버 JSON → 검토 데이터
        {for (final e in _map(j['summary']).entries) e.key: (e.value as num).toInt()}, // 판정별 개수
        [for (final m in (j['items'] as List? ?? const [])) SessionItem.fromJson(_map(m))], // 항목 목록
        j['submitted'] == true, // 제출 여부
      );
}
