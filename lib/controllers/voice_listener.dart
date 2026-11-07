import 'dart:async'; // StreamSubscription (마이크 소리 흐름을 받는 구독)
import 'dart:math' as math; // sqrt, max 계산
import 'dart:typed_data'; // Uint8List(바이트 배열), ByteData(바이트 읽고 쓰기), BytesBuilder(바이트 이어 붙이기)

import 'package:record/record.dart'; // 마이크 녹음 패키지 (AudioRecorder)

/// 버튼 없이 계속 듣다가, 말소리 구간만 잘라서 WAV(16kHz 모노 16bit)로 넘겨 주는 간단한 VAD.
///
/// - 소리 크기(RMS)가 주변 소음의 [ratio]배를 넘으면 말이 시작된 것으로 봄
/// - 말 시작 직전 0.3초도 같이 붙임 (첫 글자가 잘리지 않게)
/// - [silenceMs] 동안 조용하면 한 문장이 끝난 것으로 보고 [onUtterance] 호출
///   (측정하면서 말이 끊기는 경우가 많아 기본 1.5초. 현장 녹음으로 조정)
/// - 한 덩어리는 최대 30초
class VoiceListener {
  VoiceListener({ // 만들 때 받는 설정값
    required this.onUtterance, // 말 한 덩어리가 끝나면 호출할 함수 (필수)
    this.onLevel, // 소리 크기가 들어올 때마다 호출할 함수 (화면 표시용, 선택)
    this.silenceMs = 1500, // 몇 ms 조용하면 문장이 끝난 걸로 볼지 (기본 1.5초)
    this.ratio = 2.5, // 주변 소음의 몇 배 크기부터 말소리로 볼지
  });

  final void Function(Uint8List wav) onUtterance; // 잘라낸 WAV를 받는 함수 (화면에서 서버로 보냄)
  final void Function(double rms, bool speaking)? onLevel; // 소리 크기와 '말하는 중' 여부를 받는 함수
  int silenceMs; // 문장 끝 판단 기준 (ms)
  double ratio; // 말소리 판단 배수

  /// TTS 안내를 재생하는 동안 등 잠깐 듣지 않을 때 true.
  /// 멈출 때 모으던 소리를 버림 → 안내 음성이 문장으로 잘려 서버로 가지 않음
  bool _paused = false;
  bool get paused => _paused; // 지금 멈춘 상태인지
  set paused(bool v) {
    if (v == _paused) return; // 같은 값이면 할 일 없음
    _paused = v; // 상태 바꾸기
    _pre.clear(); // 대기 칸 비우기
    _preBytes = 0;
    _buf.clear(); // 모으던 문장 버리기
    _speaking = false; // 말하는 중 아님
    _silentMs = 0;
  }

  static const sampleRate = 16000; // 1초에 16000번 소리를 잼 (STT 모델 입력 규격)
  static const _bytesPerMs = 32; // 16000 샘플 × 2바이트 / 1000
  static const _prerollMs = 300; // 말 시작 전 0.3초를 앞에 붙임
  static const _minSpeechMs = 300; // 0.3초보다 짧은 소리는 버림 (기침, 툭 소리)
  static const _maxSpeechMs = 30000; // 한 덩어리 최대 30초
  static const _minRms = 250.0; // 아주 조용한 곳에서 숨소리에 반응하지 않게

  final AudioRecorder _rec = AudioRecorder(); // 마이크 녹음기
  StreamSubscription<Uint8List>? _sub; // 마이크 소리 조각을 계속 받는 구독 (null이면 안 듣는 중)

  final List<Uint8List> _pre = []; // 말 시작 전 소리를 잠깐 들고 있는 곳 (0.3초분)
  int _preBytes = 0; // _pre 에 든 바이트 수
  final BytesBuilder _buf = BytesBuilder(copy: false); // 지금 말하는 중인 소리를 모으는 곳
  bool _speaking = false; // 지금 말하는 중인지
  int _silentMs = 0; // 말하는 중에 조용한 시간이 얼마나 이어졌는지
  double _noise = 300; // 주변 소음 RMS 추정치 (조용할 때 계속 갱신)

  bool get isRunning => _sub != null; // 듣는 중이면 true

  /// 지금 '말소리'로 보는 기준 크기 (화면의 소리 막대에 표시)
  double get threshold => math.max(_noise * ratio, _minRms);

  /// 마이크 권한이 없으면 false
  Future<bool> start() async {
    if (_sub != null) return true; // 이미 듣는 중이면 그대로
    if (!await _rec.hasPermission()) return false; // 마이크 권한 요청 → 거절되면 false
    final stream = await _rec.startStream(const RecordConfig( // 녹음 시작: 파일이 아니라 소리 조각 흐름으로 받음
      encoder: AudioEncoder.pcm16bits, // 압축 없는 16비트 소리 (PCM)
      sampleRate: sampleRate, // 16kHz
      numChannels: 1, // 모노
    ));
    _sub = stream.listen(_onChunk); // 소리 조각이 올 때마다 _onChunk 실행
    return true; // 듣기 시작 성공
  }

  Future<void> stop() async { // 듣기 멈추기
    await _sub?.cancel(); // 구독 해제
    _sub = null; // 안 듣는 상태로
    await _rec.stop(); // 녹음기 멈춤
    _pre.clear(); // 모아 둔 소리 버리기
    _preBytes = 0;
    _buf.clear();
    _speaking = false;
    _silentMs = 0;
  }

  Future<void> dispose() async { // 화면을 나갈 때 정리
    await stop(); // 멈추고
    await _rec.dispose(); // 녹음기 자원 해제
  }

  void _onChunk(Uint8List chunk) { // 마이크에서 소리 조각이 들어올 때마다 실행
    if (_paused) return; // 잠깐 멈춤 상태면 무시
    final ms = chunk.length ~/ _bytesPerMs; // 이 조각이 몇 ms 길이인지
    final rms = _rms(chunk); // 이 조각의 소리 크기
    final loud = rms > math.max(_noise * ratio, _minRms); // 주변 소음의 3배보다 크면(그리고 최소값보다 크면) 말소리로 봄
    onLevel?.call(rms, _speaking); // 화면에 소리 크기 알려 주기

    if (!_speaking) { // 아직 말이 시작되지 않았을 때
      // 말 시작 전: 0.3초만 들고 있다가, 시작되면 앞에 붙임
      _pre.add(chunk); // 조각을 대기 칸에 넣음
      _preBytes += chunk.length;
      while (_preBytes > _prerollMs * _bytesPerMs && _pre.length > 1) { // 0.3초보다 많이 쌓이면
        _preBytes -= _pre.removeAt(0).length; // 가장 오래된 조각부터 버림
      }
      if (loud) { // 말소리가 들어오면
        _speaking = true; // 말 시작
        _silentMs = 0;
        for (final c in _pre) { // 대기 칸의 0.3초를
          _buf.add(c); // 문장 앞에 붙임
        }
        _pre.clear(); // 대기 칸 비우기
        _preBytes = 0;
      } else { // 조용하면
        _noise = _noise * 0.95 + rms * 0.05; // 주변 소음 추정치를 조금씩 갱신 (현장 소음에 맞춰짐)
      }
      return;
    }

    _buf.add(chunk); // 말하는 중: 조각을 계속 모음
    _silentMs = loud ? 0 : _silentMs + ms; // 말소리면 조용한 시간 초기화, 아니면 늘림
    final totalMs = _buf.length ~/ _bytesPerMs; // 지금까지 모은 길이 (ms)
    if (_silentMs >= silenceMs || totalMs >= _maxSpeechMs) { // 1.5초 조용했거나 30초를 넘으면 문장 끝
      final voicedMs = totalMs - _silentMs; // 실제로 말한 시간 (끝의 조용한 부분 제외)
      final pcm = _buf.takeBytes(); // 모은 소리를 꺼내고 비움
      _speaking = false; // 다시 대기 상태로
      _silentMs = 0;
      if (voicedMs >= _minSpeechMs) onUtterance(wavFromPcm16(pcm)); // 0.3초 이상이면 WAV로 만들어 넘김
    }
  }

  static double _rms(Uint8List b) { // 소리 크기(RMS) 계산: 각 샘플 값을 제곱해 평균 낸 뒤 제곱근
    final n = b.length ~/ 2; // 샘플 개수 (샘플 하나 = 2바이트)
    if (n == 0) return 0;
    final bd = ByteData.sublistView(b); // 바이트 배열을 숫자로 읽을 수 있게
    double sum = 0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little).toDouble(); // 샘플 하나 읽기 (-32768 ~ 32767)
      sum += s * s; // 제곱해서 더함
    }
    return math.sqrt(sum / n); // 평균의 제곱근
  }
}

/// PCM16 모노 → WAV 파일 바이트 (44바이트 헤더 + 데이터)
Uint8List wavFromPcm16(Uint8List pcm, {int sampleRate = VoiceListener.sampleRate}) {
  final h = ByteData(44); // WAV 파일 앞부분(헤더) 44바이트
  void tag(int offset, String s) { // 4글자 표시를 헤더에 쓰는 함수
    for (var i = 0; i < 4; i++) {
      h.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF'); // 파일 종류 표시
  h.setUint32(4, 36 + pcm.length, Endian.little); // 파일 전체 크기 - 8
  tag(8, 'WAVE'); // WAV 파일
  tag(12, 'fmt '); // 형식 정보 시작
  h.setUint32(16, 16, Endian.little); // fmt 청크 크기
  h.setUint16(20, 1, Endian.little); // PCM
  h.setUint16(22, 1, Endian.little); // 모노
  h.setUint32(24, sampleRate, Endian.little); // 16000Hz
  h.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  h.setUint16(32, 2, Endian.little); // block align
  h.setUint16(34, 16, Endian.little); // 16bit
  tag(36, 'data'); // 소리 데이터 시작
  h.setUint32(40, pcm.length, Endian.little); // 소리 데이터 크기
  return (BytesBuilder(copy: false) // 헤더와 소리를 이어 붙여 하나의 WAV 파일로
        ..add(h.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}
