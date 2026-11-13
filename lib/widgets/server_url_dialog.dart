import 'package:flutter/material.dart'; // Flutter 화면 위젯

import '../controllers/api_client.dart'; // ApiConfig (보드 주소 읽기·저장)

/// 보드 주소 입력 창. 저장하면 true, 취소하면 false.
/// 예) 192.168.0.10  →  http://192.168.0.10:8080 으로 저장 (포트를 안 쓰면 8080)
Future<bool> showServerUrlDialog(BuildContext context) async {
  final ctrl = TextEditingController(text: ApiConfig.baseUrl); // 지금 주소를 미리 넣어 둠
  String? error; // 형식 오류 문구
  final saved = await showDialog<bool>( // 창 띄우고 결과 기다리기
    context: context,
    builder: (ctx) => StatefulBuilder( // 창 안에서 오류 문구를 바꾸기 위해
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('보드 주소'), // 창 제목
        content: Column(
          mainAxisSize: MainAxisSize.min, // 내용만큼만
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField( // 주소 입력칸
              controller: ctrl,
              keyboardType: TextInputType.url, // 주소용 키보드
              autofocus: true, // 열리면 바로 입력
              decoration: InputDecoration(
                hintText: '예) 192.168.0.10', // 예시
                errorText: error, // 형식이 틀리면 빨간 글자
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text( // 도움말
              '노트북 서버: 노트북의 Wi-Fi IP\n보드: 보드 핫스팟 IP\n에뮬레이터: 10.0.2.2\nRunPod: https://<Pod ID>-8080.proxy.runpod.net',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton( // 기본값으로 되돌리기
            onPressed: () => ctrl.text = ApiConfig.defaultBaseUrl,
            child: const Text('기본값'),
          ),
          TextButton( // 취소
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton( // 저장
            onPressed: () async {
              final url = await ApiConfig.save(ctrl.text); // 다듬어서 저장
              if (url == null) { // 형식이 틀리면
                setLocal(() => error = '주소 형식이 맞지 않습니다'); // 오류 표시
                return;
              }
              if (ctx.mounted) Navigator.pop(ctx, true); // 저장 성공 → 창 닫기
            },
            child: const Text('저장'),
          ),
        ],
      ),
    ),
  );
  // ctrl.dispose() 는 하지 않음: 창이 닫히는 애니메이션 동안 아직 쓰고 있어서 오류가 날 수 있음
  return saved == true; // 저장했으면 true
}
