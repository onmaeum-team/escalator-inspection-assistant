import 'dart:async';  // 비동기 처리 (Future)
import 'dart:typed_data';  // Uint8List (녹음 바이트)

import 'package:flutter/material.dart';  // Flutter 화면 위젯
import 'package:url_launcher/url_launcher.dart';  // 보고서를 폰 브라우저로 열기
import 'package:wakelock_plus/wakelock_plus.dart';  // 점검 중 화면 꺼짐 막기

import '../constants/app_theme.dart';  // 앱 공통 색상
import '../controllers/api_client.dart';  // 서버 호출 (ApiClient, ApiOffline, ApiError)
import '../controllers/equipment_repository.dart';  // 제출 후 설비 이력 새로고침
import '../controllers/voice_guide.dart';  // 보드 TTS 음성 재생 자리 (지금은 재생 안 함)
import '../controllers/voice_listener.dart';  // 계속 듣기 VAD
import '../models/inspection_session.dart';  // 서버 응답 모델
import '../widgets/common_app_header.dart';  // 공통 상단 헤더
import '../widgets/server_url_dialog.dart';  // 보드 주소 입력 창

/// 핸즈프리 음성 점검 (보드 FastAPI 서버 연동)
///
/// 화면을 만지는 건 시작(이 화면 진입)과 끝(검토 화면에서 제출) 두 번.
/// 그 사이는 말로만:  아무 항목이나 순서 없이 말하기 · "취소" · "몇 개 남았어" · "점검 끝" · "건너뛰기"
class HandsFreeInspectionScreen extends StatefulWidget {  // 핸즈프리 점검 화면 (상태가 바뀌는 화면)
  final String equipmentId;  // 설비 번호 (예: esc-7)
  final String equipmentName;  // 설비 이름 (헤더에 표시)
  final String inspectionType;  // 'self' 월간 자체점검 / 'regular' 정기검사

  const HandsFreeInspectionScreen({  // 생성자
    super.key,
    required this.equipmentId,
    required this.equipmentName,
    this.inspectionType = 'self',
  });

  @override
  State<HandsFreeInspectionScreen> createState() => _HandsFreeInspectionScreenState();  // 화면 상태 객체 만들기
}

enum _Phase { starting, listening, error }  // 화면 단계: 시작 중 / 듣는 중 / 오류

/// 서버로 보낼 발화 하나 (연결이 끊기면 보관했다가 같은 순번으로 다시 보냄)
class _Utterance {
  final int seq;  // 발화 순번 (clientSeq). 다시 보내도 같은 번호 → 서버가 두 번 기록하지 않음
  final Uint8List? wav;  // 녹음 (또는)
  final String? text;  // 테스트 글자
  const _Utterance(this.seq, this.wav, this.text);
}

class _HandsFreeInspectionScreenState extends State<HandsFreeInspectionScreen> {  // 화면 상태
  final _api = ApiClient.instance;  // 서버 호출 도우미
  late final VoiceListener _listener;  // 마이크 VAD (initState 에서 만듦)
  final _debugText = TextEditingController();  // 테스트용 글자 입력칸
  final _voice = VoiceGuide();  // 보드 TTS 음성 재생 (audioId 가 오면)
  bool _talking = false;  // 안내 음성을 재생하는 중 (이때는 듣지 않음)
  int _sayId = 0;  // 안내 순번
  bool _reviewing = false;  // 검토 화면이 열려 있음 (이때도 듣지 않음)
  final List<_Utterance> _unsent = [];  // 연결이 끊겨 못 보낸 발화 (순서대로)
  Timer? _reconnect;  // 끊겼을 때 5초마다 연결 확인

  _Phase _phase = _Phase.starting;  // 지금 화면 단계
  String? _error;  // 오류 문구
  String? _inspectionId;  // 점검 번호 (서버가 발급)
  final Map<String, SessionItem> _items = {};  // 검사기준 번호 → 항목 결과
  int _seq = 0;  // 발화 순번 (1, 2, 3…)
  int _busy = 0; // 서버 처리 중인 발화 수
  bool _speaking = false;  // 지금 말하는 중인지 (마이크 표시용)
  double _level = 0;  // 지금 들어오는 소리 크기 (소리 막대 표시용)
  DateTime _levelAt = DateTime.now();  // 소리 막대를 마지막으로 갱신한 시각 (너무 자주 갱신하지 않게)

  String? _transcript; // 방금 들은 말
  SessionItem? _lastItem; // 방금 기록된 항목
  String? _guide; // 안내 문구 (보드 TTS 가 읽어 줄 문장)
  bool _isQuestion = false; // 안내 문구가 질문인지
  Future<void> _queue = Future.value(); // 발화를 들어온 순서대로 처리

  int? _srvRecorded;  // 서버가 알려 준 기록 수 (있으면 이걸 씀)
  int? _srvTotal;  // 서버가 알려 준 전체 수 (말한 항목이 목록에 추가·취소되면 바뀜)
  int get _recorded => _srvRecorded ?? _items.values.where((i) => i.isDone).length;  // 기록한 항목 수
  int get _total => _srvTotal ?? _items.length;  // 전체 항목 수

  @override
  void initState() {  // 화면이 처음 열릴 때 한 번 실행
    super.initState();  // 부모 초기화
    _listener = VoiceListener(  // VAD 만들기
      onUtterance: (wav) => _enqueue(wav: wav),  // 말 한 덩어리가 끝나면 서버로 보냄
      onLevel: (rms, speaking) {  // 소리가 들어올 때마다
        final now = DateTime.now();
        if (!mounted) return;
        if (speaking != _speaking || now.difference(_levelAt).inMilliseconds > 150) {  // 0.15초에 한 번만 화면 갱신
          _levelAt = now;
          setState(() {
            _speaking = speaking;
            _level = rms;
          });
        }
      },
    );
    WakelockPlus.enable().catchError((_) {});  // 점검하는 동안 화면이 꺼지지 않게 (꺼지면 마이크도 멈춤)
    _begin();  // 점검 시작
  }

  @override
  void dispose() {  // 화면을 나갈 때 정리
    _listener.dispose();  // 마이크 끄기
    _voice.stop();  // 읽던 안내 멈춤
    _reconnect?.cancel();  // 연결 확인 멈춤
    WakelockPlus.disable().catchError((_) {});  // 화면 꺼짐 다시 허용
    _debugText.dispose();  // 입력칸 정리
    super.dispose();
  }

  Future<void> _begin() async {  // 점검 시작: 서버에 점검 번호 받기 → 마이크 켜기
    setState(() {  // 로딩 화면으로
      _phase = _Phase.starting;
      _error = null;
    });
    try {
      final s = await _api.startInspection(widget.equipmentId, inspectionType: widget.inspectionType);  // POST /api/inspections
      _inspectionId = s.inspectionId;  // 점검 번호 저장
      _items  // 항목 목록 저장
        ..clear()
        ..addEntries(s.items.map((i) => MapEntry(i.itemCode, i)));  // 번호를 열쇠로 Map 에 넣음
      final ok = await _listener.start();  // 마이크 켜기 (권한 요청)
      if (!ok) {  // 권한이 없으면
        _fail('마이크 권한이 필요합니다. 설정에서 마이크를 허용해 주세요.');  // 오류 화면
        return;
      }
      setState(() {  // 듣는 화면으로 바꾸고 첫 안내
        _phase = _Phase.listening;
        _guide = widget.inspectionType == 'regular'
            ? '정기검사를 시작했습니다. 점검표 ${s.items.length}개 항목입니다. 항목과 결과를 말씀해 주세요.'
            : '자체점검을 시작했습니다. 이번 달 대상 ${s.items.length}개 항목입니다. 항목과 결과를 말씀해 주세요.';
        _isQuestion = false;
      });
    } on ApiOffline {  // 서버에 연결이 안 되면
      _fail('보드에 연결할 수 없습니다. 보드 Wi-Fi 연결을 확인해 주세요.');  // 연결 오류 안내
    } on ApiError catch (e) {  // 서버가 거절하면
      _fail(e.message.isEmpty ? e.code : e.message);  // 서버 문구 표시
    }
  }

  void _fail(String msg) {  // 오류 화면으로 바꾸는 함수
    if (!mounted) return;  // 화면이 이미 닫혔으면 무시
    setState(() {
      _phase = _Phase.error;
      _error = msg;
    });
  }

  /// 발화 하나를 순서대로 서버에 보냄 (clientSeq 로 재전송 중복 방지)
  void _enqueue({Uint8List? wav, String? text}) {  // 녹음(wav) 또는 테스트 글자(text) 하나를 보냄
    if (_inspectionId == null) return;  // 점검이 시작 전이면 무시
    final u = _Utterance(++_seq, wav, text);  // 순번을 붙여 발화 하나로 묶음
    final waiting = [..._unsent, u];  // 못 보낸 발화가 있으면 그것부터 (말한 순서 유지)
    _unsent.clear();
    for (final x in waiting) {
      _send(x);
    }
  }

  void _send(_Utterance u) {  // 발화 하나를 처리 줄에 넣음
    final id = _inspectionId;  // 점검 번호
    if (id == null) return;
    setState(() => _busy++);  // 처리 중 개수 +1 (화면에 '기록하는 중')
    _queue = _queue.then((_) async {  // 앞 발화 처리가 끝난 뒤에 이어서 처리 (순서 보장)
      try {
        final r = await _sendWithRetry(id, u);  // 끊기면 몇 번 다시 시도
        if (r != null && mounted) _apply(r);  // 결과를 화면에 반영
      } finally {  // 성공이든 실패든
        if (mounted) setState(() => _busy--);  // 처리 중 개수 -1
      }
    });
  }

  /// 끊기면 1·2·4초 기다렸다 같은 순번으로 다시 보냄. 그래도 안 되면 보관하고 null
  Future<UtteranceResult?> _sendWithRetry(String id, _Utterance u) async {
    const waits = [1, 2, 4];  // 다시 보내기 전 기다릴 시간 (초)
    for (var i = 0; ; i++) {
      if (_unsent.isNotEmpty) {  // 앞 발화가 이미 보관됐으면 이것도 보관 (순서가 바뀌지 않게)
        _unsent.add(u);
        return null;
      }
      try {
        return await _api.sendUtterance(id, u.seq, wav: u.wav, text: u.text);  // POST /api/inspections/{id}/utterances
      } on ApiOffline {  // 연결이 끊기면
        if (i >= waits.length) {  // 다시 시도도 다 실패하면
          _unsent.add(u);  // 보관
          _startReconnect();  // 5초마다 연결 확인 시작
          if (mounted) {
            setState(() {
              _guide = '보드 연결이 끊겼습니다. 방금 말씀은 보관했다가 연결되면 다시 보냅니다.';
              _isQuestion = false;
            });
          }
          return null;
        }
        if (mounted) setState(() => _guide = '보드에 다시 연결하는 중… (${i + 1}/${waits.length})');
        await Future.delayed(Duration(seconds: waits[i]));  // 잠깐 기다렸다가 다시
      } on ApiError catch (e) {  // 서버가 거절하면 (예: STT 준비 안 됨) 다시 보내도 같으니 그만
        if (mounted) setState(() => _guide = e.message.isEmpty ? e.code : e.message);  // 서버 문구 표시
        return null;
      }
    }
  }

  void _startReconnect() {  // 끊긴 동안 5초마다 서버 확인 → 살아나면 보관한 발화 보내기
    _reconnect ??= Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_unsent.isEmpty || _busy > 0) return;  // 보낼 게 없거나 처리 중이면 다음에
      try {
        await _api.health();  // GET /api/health
        _flushUnsent();  // 살아났으면 보관한 것 보내기
      } catch (_) {}  // 아직 끊김
    });
  }

  void _flushUnsent() {  // 보관한 발화를 순서대로 다시 보냄
    _reconnect?.cancel();  // 확인 멈춤
    _reconnect = null;
    final waiting = [..._unsent];
    _unsent.clear();
    if (mounted && waiting.isNotEmpty) setState(() => _guide = '다시 연결됐습니다. 보관한 말 ${waiting.length}개를 보냅니다.');
    for (final x in waiting) {
      _send(x);
    }
  }

  /// 보드 TTS 음성 재생. 재생하는 동안은 듣지 않음 (앱이 안내 소리를 받아쓰지 않게)
  Future<void> _say(String text, {String? audioId}) async {
    final my = ++_sayId;  // 이번 안내 번호 (앞 안내가 끊기고 새 안내가 나올 때 구분용)
    _talking = true;
    _syncListening();  // 듣기 멈춤
    if (mounted) setState(() {});  // '안내 중…' 표시
    await _voice.speak(text, audioId: audioId);  // 다 읽을 때까지 기다림
    await Future.delayed(const Duration(milliseconds: 300));  // 스피커 울림이 사라질 때까지 잠깐
    if (my != _sayId) return;  // 그사이 새 안내가 시작됐으면 그쪽이 끝날 때 다시 듣기
    _talking = false;
    _syncListening();  // 다시 듣기
    if (mounted) setState(() {});  // 상태 문구 되돌리기
  }

  void _syncListening() => _listener.paused = _talking || _reviewing;  // 안내 중이거나 검토 중이면 멈춤

  Future<void> _changeServer() async {  // 보드 주소 바꾸기
    final changed = await showServerUrlDialog(context);  // 입력 창
    if (!changed || !mounted) return;
    if (_phase == _Phase.error) {
      _begin();  // 오류 화면이었으면 새 주소로 다시 시작
    } else if (_unsent.isNotEmpty) {
      _flushUnsent();  // 점검 중이었으면 보관한 말을 새 주소로 보냄
    } else {
      setState(() {});  // 화면의 주소 표시만 갱신
    }
  }

  void _apply(UtteranceResult r) {  // 서버 결과를 화면 상태에 반영하는 함수
    setState(() {  // 화면 갱신
      if (r.transcript != null) _transcript = r.transcript;  // 받아쓴 문장 표시
      if (r.total > 0) {  // 서버가 진행률을 보냈으면 그대로 씀
        _srvRecorded = r.recorded;
        _srvTotal = r.total;
      }
      final item = r.item;  // 기록·변경된 항목
      if (item != null) {
        _items[item.itemCode] = item;  // 항목 결과 갱신
        _lastItem = item.isDone || r.kind == 'question' ? item : null;  // 기록됐거나 질문 중이면 '방금 기록' 카드로 표시
      }
      if (r.kind == 'ignored') return; // 잡담: 화면 그대로
      _guide = r.speech?.text ?? _guide;  // 안내 문구 갱신
      _isQuestion = r.kind == 'question' ||  // 질문이거나
          (r.command == 'finish' && r.missing.isNotEmpty);  // '점검 끝'인데 빠진 항목이 있으면 질문 모양(주황, 크게)으로
    });
    final sp = r.speech;  // 안내 문장
    if (r.kind != 'ignored' && sp?.audioId != null) _say(sp!.text, audioId: sp!.audioId);  // 보드 TTS 음성이 있으면 재생
    if (r.command == 'finish' && r.missing.isEmpty) _openReview();  // '점검 끝'이고 빠진 게 없으면 검토 화면으로
  }

  Future<void> _finishByButton() async {  // '점검 끝내고 검토하기' 버튼
    final id = _inspectionId;  // 점검 번호
    if (id == null) return;  // 없으면 무시
    try {
      final r = await _api.finish(id);  // POST /api/inspections/{id}/finish
      if (!mounted) return;  // 화면이 닫혔으면 무시
      if (r.missing.isEmpty) {  // 빠진 항목이 없으면
        _openReview();  // 검토 화면으로
      } else {
        _apply(r);  // 있으면 음성 '점검 끝'과 같게 질문 표시
      }
    } on ApiOffline {  // 연결이 끊기면
      _openReview(); // 연결이 끊겨도 검토 화면에서 다시 시도
    }
  }

  Future<void> _openReview() async {  // 검토 화면 열기
    final id = _inspectionId;  // 점검 번호
    if (id == null) return;  // 없으면 무시
    _reviewing = true;
    _syncListening();  // 검토하는 동안 듣지 않음
    await Navigator.push(  // 검토 화면으로 이동하고 돌아올 때까지 기다림
      context,
      MaterialPageRoute(
        builder: (_) => InspectionReviewScreen(  // 검토 화면 만들기
          inspectionId: id,
          equipmentId: widget.equipmentId,
          equipmentName: widget.equipmentName,
        ),
      ),
    );
    _reviewing = false;
    _syncListening(); // 검토 화면에서 돌아오면 다시 듣기
  }

  @override
  Widget build(BuildContext context) {  // 화면 그리기
    return Scaffold(  // 기본 화면 틀
      backgroundColor: AppColors.background,  // 배경색
      appBar: CommonAppHeader(  // 상단 헤더
        title: widget.equipmentName,  // 제목 = 설비 이름
        subtitle: '${widget.inspectionType == 'regular' ? '정기검사' : '자체점검'} · 버튼 없이, 아무 항목이나 말씀하세요',  // 부제
      ),
      body: SafeArea(  // 노치·하단바를 피해서
        child: switch (_phase) {  // 단계에 따라 다른 화면
          _Phase.starting => const Center(child: CircularProgressIndicator()),  // 시작 중: 로딩
          _Phase.error => _ErrorView(message: _error ?? '오류', onRetry: _begin, onServer: _changeServer),  // 오류: 오류 화면 + 다시 시도 + 주소 바꾸기
          _Phase.listening => _listeningView(),  // 듣는 중: 아래 함수
        },
      ),
    );
  }

  Widget _listeningView() {  // 듣는 중 화면
    final total = _total;  // 전체 항목 수 (서버 기준)
    return ListView(  // 세로로 스크롤되는 목록
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),  // 여백
      children: [
        // 진행률
        Row(  // 가로 한 줄
          children: [
            const Text('기록한 항목',  // 왼쪽 글자
                style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
            const Spacer(),  // 가운데 빈칸
            Text('$_recorded / $total',  // 오른쪽: '2 / 5'
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(  // 모서리 둥글게
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(  // 진행 막대
            value: total == 0 ? 0 : _recorded / total,  // 채워진 비율
            minHeight: 8,  // 막대 두께
            backgroundColor: AppColors.border,  // 빈 부분 색
          ),
        ),
        const SizedBox(height: 24),

        // 듣는 중 표시
        Center(
          child: AnimatedContainer(  // 크기가 부드럽게 바뀌는 원
            duration: const Duration(milliseconds: 200),  // 0.2초 동안 바뀜
            width: _speaking ? 128 : 112,  // 말하는 중이면 조금 커짐
            height: _speaking ? 128 : 112,
            decoration: BoxDecoration(  // 원 모양
              color: _busy > 0 ? AppColors.warning : AppColors.primary,  // 처리 중이면 주황, 아니면 파랑
              shape: BoxShape.circle,
            ),
            child: Icon(_busy > 0 ? Icons.hourglass_top : Icons.mic,  // 처리 중이면 모래시계, 아니면 마이크 아이콘
                color: Colors.white, size: 48),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            _talking ? '안내 중…' : _busy > 0 ? '기록하는 중…' : (_speaking ? '듣고 있어요' : '말씀하세요'),  // 상태 문구
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 8),
        // 소리 막대: 마이크에 소리가 들어오는지, 기준선을 넘는지 확인용
        _LevelBar(level: _level, threshold: _listener.threshold, paused: _listener.paused),
        const SizedBox(height: 24),

        // 안내 문구 (질문이면 크게)
        if (_guide != null)  // 안내 문구가 있으면
          _Box(  // 상자
            color: _isQuestion ? AppColors.warningBg : AppColors.primaryBg,  // 질문이면 주황 배경, 아니면 파란 배경
            child: Text(
              _guide!,  // 안내 문장
              style: TextStyle(
                fontSize: _isQuestion ? 22 : 16,  // 질문이면 크게
                fontWeight: FontWeight.bold,
                color: _isQuestion ? AppColors.warning : AppColors.primary,  // 글자색
              ),
            ),
          ),
        if (_transcript != null) ...[  // 받아쓴 문장이 있으면
          const SizedBox(height: 12),
          _Box(  // 흰 상자
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('방금 들은 말',  // 작은 제목
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                Text('“$_transcript”', style: const TextStyle(fontSize: 16)),  // 받아쓴 문장 (따옴표)
              ],
            ),
          ),
        ],
        if (_lastItem != null) ...[  // 방금 기록한 항목이 있으면
          const SizedBox(height: 12),
          _ItemCard(item: _lastItem!),  // 항목 카드 (아래 _ItemCard)
        ],
        const SizedBox(height: 24),

        // 말로 할 수 있는 것
        const Text('말로 할 수 있는 것',  // 음성 명령 안내 제목
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        const Wrap(  // 줄이 넘치면 다음 줄로
          spacing: 8,
          runSpacing: 8,
          children: [
            _Hint('“취소”'),  // 말로 할 수 있는 명령들
            _Hint('“다시 읽어 줘”'),
            _Hint('“몇 개 남았어?”'),
            _Hint('“점검 끝”'),
            _Hint('“건너뛰기”'),
            _Hint('“나머지 건너뛰기”'),  // 남은 항목 전부 미점검 → 검토 화면
          ],
        ),
        const SizedBox(height: 24),

        // 장갑을 벗었을 때를 위한 버튼
        SizedBox(  // 버튼 크기
          height: 56,
          child: OutlinedButton(  // 테두리 버튼
            onPressed: _finishByButton,  // 누르면 점검 끝 처리
            child: const Text('점검 끝내고 검토하기', style: TextStyle(fontSize: 16)),  // 버튼 글자
          ),
        ),

        // 연결이 끊겨 보관 중인 말
        if (_unsent.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: FilledButton.tonal(
              onPressed: _flushUnsent,  // 지금 다시 보내기
              child: Text('보관한 말 ${_unsent.length}개 다시 보내기'),
            ),
          ),
        ],

        // 보드 주소 (실제 폰에서는 보드 IP 로 바꿔야 함)
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text('보드: ${ApiConfig.baseUrl}',  // 지금 주소
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ),
            TextButton(onPressed: _changeServer, child: const Text('주소 바꾸기')),
          ],
        ),

        // 테스트용: STT 없이 글자로 보내기
        const SizedBox(height: 12),
        ExpansionTile(  // 눌러야 펼쳐지는 칸
          tilePadding: EdgeInsets.zero,
          title: const Text('테스트: 글자로 보내기',  // 접힌 상태의 제목
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(  // 글자 입력칸
                    controller: _debugText,  // 입력칸 내용
                    decoration: const InputDecoration(
                      hintText: '예) 스텝 롤러 고무 벗겨졌어 부적합',  // 예시 문구
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(  // 보내기 버튼
                  onPressed: () {  // 누르면
                    final t = _debugText.text.trim();  // 입력한 글자 (앞뒤 공백 제거)
                    if (t.isEmpty) return;  // 비었으면 무시
                    _debugText.clear();  // 입력칸 비우기
                    _enqueue(text: t);  // 녹음 대신 글자로 서버에 보냄
                  },
                  child: const Text('보내기'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// 검토 · 제출 (화면을 만지는 두 번째이자 마지막 단계)
class InspectionReviewScreen extends StatefulWidget {  // 검토 · 제출 화면
  final String inspectionId;  // 점검 번호
  final String equipmentId;  // 설비 번호
  final String equipmentName;  // 설비 이름

  const InspectionReviewScreen({
    super.key,
    required this.inspectionId,
    required this.equipmentId,
    required this.equipmentName,
  });

  @override
  State<InspectionReviewScreen> createState() => _InspectionReviewScreenState();  // 화면 상태 객체 만들기
}

class _InspectionReviewScreenState extends State<InspectionReviewScreen> {  // 검토 화면 상태
  final _api = ApiClient.instance;  // 서버 호출 도우미
  InspectionResultData? _data;  // 서버에서 받은 결과
  String? _error;  // 오류 문구
  bool _submitting = false;  // 제출 중인지 (버튼 막기)

  @override
  void initState() {  // 화면이 처음 열릴 때
    super.initState();
    _load();  // 결과 불러오기
  }

  Future<void> _load() async {  // 결과 불러오기 함수
    try {
      final d = await _api.result(widget.inspectionId);  // GET /api/inspections/{id}/result
      if (mounted) setState(() => _data = d);  // 받은 결과로 화면 갱신
    } on ApiOffline {  // 연결이 안 되면
      if (mounted) setState(() => _error = '보드에 연결할 수 없습니다.');  // 오류 표시
    } on ApiError catch (e) {  // 서버가 거절하면
      if (mounted) setState(() => _error = e.message);  // 오류 표시
    }
  }

  Future<void> _submit({bool acknowledgeMissing = false}) async {  // 제출 함수 (acknowledgeMissing = 미점검이 있어도 제출)
    setState(() => _submitting = true);  // 버튼 잠금
    try {
      await _api.submit(widget.inspectionId, acknowledgeMissing: acknowledgeMissing);  // POST /api/inspections/{id}/submit
      await EquipmentRepository.instance.syncHistory(widget.equipmentId);  // 이력 화면에 새 점검이 보이게 새로고침
      if (!mounted) return;  // 화면이 닫혔으면 무시
      final report = _api.reportUri(widget.inspectionId);  // 보고서 주소 (보드에 저장됨)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(  // 아래 알림 + '보고서 보기' 버튼
        content: const Text('점검 결과를 제출했습니다. 보고서가 보드에 저장됐어요.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: '보고서 보기', onPressed: () => openReport(report)),
      ));
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);  // 홈 화면으로 돌아가기 (뒤로가기 기록 지움)
    } on ApiError catch (e) {  // 서버가 거절하면
      if (!mounted) return;  // 화면이 닫혔으면 무시
      if (e.code == 'MISSING_REQUIRED_ITEMS') {  // 미점검 항목이 있다는 거절이면
        final ok = await showDialog<bool>(  // 확인 창 띄우기
          context: context,
          builder: (c) => AlertDialog(  // 확인 창
            title: const Text('미점검 항목이 있습니다'),  // 제목
            content: Text('${e.message}\n미점검으로 남기고 제출할까요?'),  // 서버 문구 + 질문
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('돌아가기')),  // 취소 → false
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('제출')),  // 제출 → true
            ],
          ),
        );
        if (ok == true) {  // 제출을 눌렀으면
          setState(() => _submitting = false);  // 버튼 잠금 풀고
          await _submit(acknowledgeMissing: true);  // 미점검 인정하고 다시 제출
          return;  // 끝
        }
      } else {  // 그 밖의 거절이면
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));  // 서버 문구를 아래 알림으로
      }
    } on ApiOffline {  // 연결이 안 되면
      if (mounted) {  // 화면이 열려 있으면
        ScaffoldMessenger.of(context)  // 연결 오류 알림
            .showSnackBar(const SnackBar(content: Text('보드에 연결할 수 없습니다.')));
      }
    } finally {  // 마지막에 항상
      if (mounted) setState(() => _submitting = false);  // 버튼 잠금 풀기
    }
  }

  Future<void> _edit(SessionItem item) async {  // 항목 손 수정 함수
    final status = await showModalBottomSheet<String>(  // 아래에서 올라오는 선택 창
      context: context,
      builder: (c) => SafeArea(  // 선택 창 내용
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in ['적합', '부적합', '해당없음'])  // 세 가지 판정
              ListTile(title: Text(s), onTap: () => Navigator.pop(c, s)),  // 누르면 그 판정을 돌려주고 닫힘
          ],
        ),
      ),
    );
    if (status == null) return;  // 아무것도 안 골랐으면 끝
    try {
      await _api.editItem(widget.inspectionId, item.itemCode, {'status': status});  // PATCH /api/inspections/{id}/items/{itemCode}
      await _load();  // 다시 불러와 화면 갱신
    } on ApiError catch (e) {  // 서버가 거절하면 (예: 부적합인데 특기사항 없음)
      if (mounted) {  // 화면이 열려 있으면
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));  // 서버 문구 알림
      }
    } on ApiOffline {  // 연결이 안 되면
      // 연결이 끊긴 경우: 다음에 다시 시도
    }
  }

  @override
  Widget build(BuildContext context) {  // 화면 그리기
    final d = _data;  // 받은 결과
    return Scaffold(  // 기본 화면 틀
      backgroundColor: AppColors.background,  // 배경색
      appBar: const CommonAppHeader(title: '검토 · 제출', subtitle: '확인하고 제출하세요'),  // 상단 헤더
      body: SafeArea(  // 노치·하단바 피하기
        child: d == null  // 결과가 아직 없으면
            ? Center(
                child: _error == null  // 오류도 없으면
                    ? const CircularProgressIndicator()  // 로딩
                    : _ErrorView(message: _error!, onRetry: _load),  // 오류가 있으면 오류 화면
              )
            : Column(  // 결과가 있으면 세로 배치
                children: [
                  Padding(  // 위쪽 여백
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(  // 가로 한 줄 (요약 3칸)
                      children: [
                        for (final s in ['적합', '부적합', '미확인'])  // 적합·부적합·미점검 칸
                          Expanded(  // 칸을 똑같이 나눔
                            child: _Box(  // 흰 상자
                              color: Colors.white,
                              child: Column(
                                children: [
                                  Text('${d.summary[s] ?? 0}',  // 개수
                                      style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          color: _statusColor(s))),  // 판정별 색
                                  Text(s == '미확인' ? '미점검' : s,  // 이름 ('미확인'은 '미점검'으로 표시)
                                      style: const TextStyle(
                                          fontSize: 12, color: AppColors.textSecondary)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(  // 남은 공간을 차지
                    child: ListView(  // 스크롤 목록
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        // 부적합 · 미점검을 먼저
                        for (final it in [  // 부적합 → 미점검 → 나머지 순서로
                          ...d.items.where((i) => i.status == '부적합'),  // 부적합
                          ...d.items.where((i) => i.status == '미확인'),  // 미점검
                          ...d.items.where((i) => i.status != '부적합' && i.status != '미확인'),  // 나머지
                        ])
                          Padding(  // 카드 사이 간격
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _ItemCard(item: it, onEdit: () => _edit(it)),  // 항목 카드 + 수정 버튼
                          ),
                      ],
                    ),
                  ),
                  Padding(  // 아래 여백
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(  // 버튼 크기
                      width: double.infinity,  // 가로 꽉 차게
                      height: 56,  // 높이
                      child: FilledButton(  // 채워진 버튼
                        onPressed: _submitting ? null : () => _submit(),  // 제출 중이면 눌리지 않게
                        child: Text(_submitting ? '제출 중…' : '제출하고 보고서 만들기',  // 버튼 글자
                            style: const TextStyle(fontSize: 16)),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 보고서를 폰 브라우저로 열기 (인쇄·PDF 저장은 브라우저에서)
Future<void> openReport(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}  // 브라우저를 못 열면 조용히 넘어감
}

/// 지난 점검 상세 (이력 화면에서 기록을 누르면). 읽기만 하고, 보고서를 열 수 있음
class InspectionDetailScreen extends StatefulWidget {
  final String inspectionId;  // 점검 번호
  final String title;  // 헤더 제목 (점검 날짜)
  const InspectionDetailScreen({super.key, required this.inspectionId, required this.title});

  @override
  State<InspectionDetailScreen> createState() => _InspectionDetailScreenState();
}

class _InspectionDetailScreenState extends State<InspectionDetailScreen> {
  final _api = ApiClient.instance;
  InspectionResultData? _data;  // 서버에서 받은 결과
  String? _error;  // 오류 문구

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.result(widget.inspectionId);  // GET /api/inspections/{id}/result
      if (mounted) setState(() => _data = d);
    } on ApiOffline {
      if (mounted) setState(() => _error = '보드에 연결할 수 없습니다.');
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _error = e.status == 404
            ? '이 기록은 상세 결과가 없어요.\n(앱에 들어 있던 시연용 예시 기록이거나, 보드에 저장되기 전 기록이에요)'
            : e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: CommonAppHeader(title: '${widget.title} 점검', subtitle: widget.inspectionId),
      body: SafeArea(
        child: d == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : _ErrorView(message: _error!, onRetry: _load),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _Box(  // 점검 정보
                    color: Colors.white,
                    child: Text(
                      '점검자 ${d.inspector ?? '-'} · 소요 ${d.durationMinutes ?? '-'}분\n'
                      '제출 ${(d.submittedAt ?? '-').replaceFirst('T', ' ')}',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(  // 판정별 개수
                    children: [
                      for (final s in ['적합', '부적합', '미확인'])
                        Expanded(
                          child: _Box(
                            color: Colors.white,
                            child: Column(children: [
                              Text('${d.summary[s] ?? 0}',
                                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _statusColor(s))),
                              Text(s == '미확인' ? '미점검' : s,
                                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                            ]),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (d.reportUrl != null)  // 제출한 점검이면 보고서 버튼
                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: () => openReport(_api.reportUri(widget.inspectionId)),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('보고서 보기 (인쇄·PDF 저장)'),
                      ),
                    ),
                  const SizedBox(height: 12),
                  for (final it in [  // 부적합 → 미점검 → 나머지 순서
                    ...d.items.where((i) => i.status == '부적합'),
                    ...d.items.where((i) => i.status == '미확인'),
                    ...d.items.where((i) => i.status != '부적합' && i.status != '미확인'),
                  ])
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: _ItemCard(item: it)),  // 수정 버튼 없이
                ],
              ),
      ),
    );
  }
}

// ───────────── 작은 위젯들 ─────────────

Color _statusColor(String s) => switch (s) {  // 판정 → 색 (적합 초록, 부적합 빨강, 해당없음 회색, 미확인 주황)
      '적합' => AppColors.normal,  // 적합
      '부적합' => AppColors.danger,  // 부적합
      '해당없음' => AppColors.textSecondary,  // 해당없음
      _ => AppColors.warning,  // 그 밖(미확인)
    };

class _Box extends StatelessWidget {  // 흰 상자 위젯 (여러 곳에서 씀)
  final Color color;  // 배경색
  final Widget child;  // 안에 넣을 내용
  const _Box({required this.color, required this.child});  // 생성자

  @override
  Widget build(BuildContext context) => Container(  // 상자 그리기
        width: double.infinity,  // 가로 꽉 차게
        margin: const EdgeInsets.symmetric(horizontal: 2),  // 바깥 여백
        padding: const EdgeInsets.all(14),  // 안쪽 여백
        decoration: BoxDecoration(  // 모양
          color: color,  // 배경색
          borderRadius: BorderRadius.circular(12),  // 모서리 둥글게
          border: Border.all(color: AppColors.border),  // 테두리
        ),
        child: child,  // 내용
      );
}

class _ItemCard extends StatelessWidget {  // 항목 결과 카드
  final SessionItem item;  // 보여줄 항목
  final VoidCallback? onEdit;  // 수정 버튼을 눌렀을 때 (없으면 버튼 숨김)
  const _ItemCard({required this.item, this.onEdit});  // 생성자

  @override
  Widget build(BuildContext context) {  // 카드 그리기
    final c = _statusColor(item.status);  // 판정 색
    return _Box(  // 흰 상자 안에
      color: Colors.white,
      child: Column(  // 세로 배치
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(  // 윗줄
            children: [
              Text(item.itemCode,  // 검사기준 번호
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const Spacer(),  // 가운데 빈칸
              Container(  // 판정 배지
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),  // 배지 여백
                decoration: BoxDecoration(  // 배지 모양
                  color: c.withValues(alpha: 0.12),  // 판정 색을 옅게
                  borderRadius: BorderRadius.circular(999),  // 알약 모양
                ),
                child: Text(item.status == '미확인' ? '미점검' : item.status,  // 판정 글자 ('미확인'은 '미점검')
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: c)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(  // 항목 이름
            [item.itemName, if (item.location != null) item.location!].join(' · '),  // 이름 · 위치 (위치가 있을 때만)
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          if (item.note != null) ...[  // 특기사항이 있으면
            const SizedBox(height: 4),
            Text('특기사항: ${item.note}', style: const TextStyle(fontSize: 14)),  // 특기사항
          ],
          if (item.criteria != null) ...[  // 판정 기준이 있으면 (규칙 엔진 판정)
            const SizedBox(height: 2),
            Text('기준: ${item.criteria}',  // 기준 표시
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
          if (onEdit != null)  // 수정 버튼이 필요하면
            Align(
              alignment: Alignment.centerRight,  // 오른쪽 정렬
              child: TextButton(onPressed: onEdit, child: const Text('수정')),  // 수정 버튼
            ),
        ],
      ),
    );
  }
}

class _LevelBar extends StatelessWidget {  // 마이크 소리 크기 막대 (기준선을 넘으면 말소리로 봄)
  final double level;  // 지금 소리 크기
  final double threshold;  // 말소리 기준
  final bool paused;  // 듣기 멈춤 상태
  const _LevelBar({required this.level, required this.threshold, required this.paused});

  @override
  Widget build(BuildContext context) {
    final max = threshold * 3;  // 막대 끝 = 기준의 3배
    final v = (level / max).clamp(0.0, 1.0);  // 막대 채움 비율
    final t = (threshold / max).clamp(0.0, 1.0);  // 기준선 위치 (1/3 지점)
    final over = level >= threshold;  // 기준을 넘었는지
    return Column(
      children: [
        LayoutBuilder(
          builder: (_, c) => Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: v,
                  minHeight: 10,
                  backgroundColor: AppColors.border,
                  color: over ? AppColors.normal : AppColors.textSecondary,  // 넘으면 초록
                ),
              ),
              Positioned(  // 기준선
                left: c.maxWidth * t,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: AppColors.danger),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          paused ? '듣기 멈춤' : '마이크 소리 ${level.round()} / 기준 ${threshold.round()}',  // 숫자로도 표시
          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {  // 음성 명령 안내 칩
  final String text;  // 칩 글자
  const _Hint(this.text);  // 생성자

  @override
  Widget build(BuildContext context) => Container(  // 칩 그리기
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),  // 안쪽 여백
        decoration: BoxDecoration(  // 모양
          color: Colors.white,  // 흰 배경
          borderRadius: BorderRadius.circular(999),  // 알약 모양
          border: Border.all(color: AppColors.border),  // 테두리
        ),
        child: Text(text, style: const TextStyle(fontSize: 13)),  // 글자
      );
}

class _ErrorView extends StatelessWidget {  // 오류 화면 위젯
  final String message;  // 오류 문구
  final VoidCallback onRetry;  // 다시 시도 버튼을 눌렀을 때
  final VoidCallback? onServer;  // 보드 주소 바꾸기 버튼을 눌렀을 때 (없으면 버튼 숨김)
  const _ErrorView({required this.message, required this.onRetry, this.onServer});  // 생성자

  @override
  Widget build(BuildContext context) => Padding(  // 그리기
        padding: const EdgeInsets.all(24),  // 여백
        child: Column(  // 세로 배치
          mainAxisAlignment: MainAxisAlignment.center,  // 가운데 정렬
          children: [
            const Icon(Icons.wifi_off, size: 48, color: AppColors.textSecondary),  // 와이파이 끊김 아이콘
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),  // 오류 문구
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('다시 시도')),  // 다시 시도 버튼
            if (onServer != null) ...[  // 핸즈프리 화면에서만 주소 바꾸기 표시
              const SizedBox(height: 8),
              Text('보드: ${ApiConfig.baseUrl}',  // 지금 주소 (틀렸는지 확인)
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              TextButton(onPressed: onServer, child: const Text('보드 주소 바꾸기')),  // 주소 입력 창
            ],
          ],
        ),
      );
}
