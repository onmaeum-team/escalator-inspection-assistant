import 'package:flutter/material.dart';
import 'package:record/record.dart'; // 앱 시작 때 마이크 권한 요청

import '../constants/app_theme.dart';
import '../controllers/equipment_repository.dart';
import 'home_screen.dart';
import 'scan_screen.dart';

/// 하단 탭: 설비 스캔(프레임 1) / 점검 기록(프레임 2)
/// 온디바이스 데이터는 여기서 한 번 불러옴 → main.dart 는 건드리지 않아도 됨.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final _repo = EquipmentRepository.instance;
  int _index = 0;

  static const _pages = [ScanScreen(), HomeScreen()];

  @override
  void initState() {
    super.initState();
    _repo.init();
    WidgetsBinding.instance.addPostFrameCallback((_) => _askMic()); // 첫 화면이 뜬 직후 마이크 권한 묻기
  }

  /// 앱을 켜자마자 마이크 권한을 물어 둠 (핸즈프리 점검 중에 묻지 않게).
  /// 카메라 권한은 첫 화면(스캔)에서 카메라가 켜질 때 자동으로 물어봄.
  Future<void> _askMic() async {
    final rec = AudioRecorder();
    try {
      final ok = await rec.hasPermission(); // 처음이면 권한 창이 뜸
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('마이크 권한이 없으면 음성 점검을 할 수 없어요. 설정 > 앱 > 권한에서 허용해 주세요.'),
        ));
      }
    } catch (_) {
    } finally {
      await rec.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _repo,
      builder: (context, _) {
        if (!_repo.isLoaded) {
          return const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('온디바이스 DB 불러오는 중...',
                      style: TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          body: SafeArea(child: IndexedStack(index: _index, children: _pages)),
          bottomNavigationBar: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: NavigationBar(
              height: 64,
              backgroundColor: AppColors.surface,
              indicatorColor: Colors.transparent,
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.qr_code_scanner,
                      color: AppColors.textSecondary),
                  selectedIcon:
                      Icon(Icons.qr_code_scanner, color: AppColors.primary),
                  label: '설비 스캔',
                ),
                NavigationDestination(
                  icon:
                      Icon(Icons.cloud_outlined, color: AppColors.textSecondary),
                  selectedIcon: Icon(Icons.cloud, color: AppColors.primary),
                  label: '점검 기록',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
