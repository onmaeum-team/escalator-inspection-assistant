import 'package:flutter/material.dart';
import 'controllers/api_client.dart'; // 저장된 보드 주소 불러오기
import 'screens/inspection_screen.dart';
import 'screens/main_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized(); // 앱 시작 전에 휴대폰 저장소를 쓰려면 필요
  await ApiConfig.load(); // 저장해 둔 보드 주소 불러오기
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Elevator/Escalator Inspection App',
      debugShowCheckedModeBanner: false, 
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xfff5f5f5),
        primaryColor: const Color(0xff4c6ef5),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const MainShell(),
        '/inspect': (_) => const InspectionScreen(),
      },
    );
  }
}