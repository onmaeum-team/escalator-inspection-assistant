/// 서버가 돌려준 안내(speech)를 소리로 들려주는 곳.
///
/// 음성은 보드 TTS(VITS)가 만든다. 서버 응답의 speech.audioId 가 오면
/// ApiConfig.audioUrl(audioId) 의 WAV 를 재생하면 됨.
/// TODO: 보드 TTS 가 붙으면 오디오 재생 패키지(예: just_audio)로 speak() 안을 채우기.
///       화면 코드는 그대로 둬도 됨 (재생하는 동안 듣기를 멈추는 처리는 이미 되어 있음).
class VoiceGuide {
  /// 안내 재생. 재생이 끝날 때 끝나야 함 (그동안 마이크를 멈춰 둠).
  /// 지금은 보드 TTS 가 없어서 아무것도 재생하지 않음 → 화면 글자로만 안내.
  Future<void> speak(String text, {String? audioId}) async {
    if (audioId == null) return; // 보드 음성이 없으면 재생할 것 없음
    // TODO: ApiConfig.audioUrl(audioId) 재생하고, 끝날 때까지 기다리기
  }

  Future<void> stop() async {} // 재생 중인 안내 멈춤 (재생 기능이 생기면 채우기)
}
