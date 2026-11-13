import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart'; // 카메라 QR 스캔

import '../constants/app_theme.dart';
import '../controllers/equipment_repository.dart';
import '../widgets/common_widgets.dart';
import '../widgets/equipment_sheet.dart';
import '../widgets/common_app_header.dart';

/// 프레임 1 — 설비 스캔 (QR)
///
/// 스캔 → EquipmentSheet(바텀시트)
///   · 등록된 설비      : 이번 달 필수 항목 + [이력 보기] [점검 시작]
///   · 온디바이스 DB 설비 : [등록하고 이력 가져오기]
///   · DB에 없는 설비    : 이름/위치 입력 후 등록
///
/// QR: 박스를 누르면 카메라가 켜지고, 읽으면 _onDetect → _handleQr (읽고 나면 카메라 꺼짐)
/// 박스를 길게 누르면 '테스트용 QR 선택' 창 (QR 코드가 없을 때 시연용)
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _repo = EquipmentRepository.instance;

  bool _looking = false;

  /// 카메라 (QR 만, 같은 코드를 연달아 읽지 않게). 박스를 누를 때만 켬
  final MobileScannerController _cam = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _camActive = false; // 지금 카메라가 켜져 있는지

  /// 박스를 누르면 카메라 켜기 / 다시 누르면 끄기 (처음 켤 때 카메라 권한을 물어봄)
  Future<void> _toggleCam() async {
    if (_camActive) {
      setState(() => _camActive = false);
      await _camOff();
    } else {
      setState(() => _camActive = true);
      await _camOn();
    }
  }

  @override
  void dispose() {
    _cam.dispose(); // 카메라 끄기
    super.dispose();
  }

  Future<void> _camOn() async {
    try {
      await _cam.start(); // 이미 켜져 있으면 오류가 날 수 있어 무시
    } catch (_) {}
  }

  Future<void> _camOff() async {
    try {
      await _cam.stop();
    } catch (_) {}
  }

  /// 카메라가 QR 을 읽었을 때
  Future<void> _onDetect(BarcodeCapture capture) async {
    final raw = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue; // 읽은 글자
    if (raw == null || raw.isEmpty || _looking) return; // 비었거나 이미 처리 중이면 무시
    if (mounted) setState(() => _camActive = false); // 읽었으면 카메라 끄기
    await _camOff();
    await _handleQr(raw); // 설비 조회 → 바텀시트 (다시 스캔하려면 박스를 누르면 됨)
  }

  /// QR에서 읽은 문자열로 설비 조회
  Future<void> _handleQr(String raw) async {
    if (_looking) return;

    setState(() => _looking = true);

    try {
      final lookup = await _repo.lookup(raw);

      if (!mounted) return;

      await EquipmentSheet.show(context, lookup);
    } finally {
      if (mounted) {
        setState(() => _looking = false);
      }
    }
  }

  /// 테스트용 QR 선택
  Future<void> _simulateScan() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text(
          '테스트용 QR 선택',
          style: TextStyle(fontSize: 17),
        ),
        children: [
          _option(ctx, 'esc-3', '3호기', '등록된 설비'),
          _option(
            ctx,
            'esc-7',
            '7호기',
            '새 설비 · 온디바이스 DB에 이력 있음',
          ),
          _option(
            ctx,
            '{"id":"esc-8"}',
            '8호기 (JSON QR)',
            '새 설비 · 이력 있음 · 누락 항목 있음',
          ),
          _option(
            ctx,
            'esc-99',
            '알 수 없는 QR',
            'DB에 없는 설비 → 직접 등록',
          ),
          const Divider(),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__reset__'),
            child: const Text(
              '테스트 데이터 초기화',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );

    if (picked == null || !mounted) return;

    if (picked == '__reset__') {
      await _repo.resetForTest();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('담당 설비를 처음 상태(1·2·3호기)로 되돌렸어요'),
        ),
      );
      return;
    }

    await _handleQr(picked);
  }

  Widget _option(
    BuildContext ctx,
    String payload,
    String title,
    String desc,
  ) {
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(ctx, payload),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CommonAppHeader(
        title: '설비 스캔',
        subtitle: '설비의 QR 코드를 비춰주세요',
        showBackButton: false,
        showOfflineBadge: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: _repo,
              builder: (context, _) {
                final recent = _repo.recentEquipments();

                return ScrollConfiguration(
                  // 스크롤 끝에서 콘텐츠가 늘어나는 효과 제거
                  behavior: ScrollConfiguration.of(context).copyWith(
                    overscroll: false,
                  ),
                  child: ListView(
                    // 스크롤 끝에서 늘어나거나 튕기는 효과 방지
                    physics: const ClampingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    children: [
                      Center(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            _ScannerBox(
                              onTap: _toggleCam,
                              onLongPress: _simulateScan,
                              active: _camActive,
                              controller: _cam,
                              onDetect: _onDetect,
                            ),
                            if (_looking)
                              const CircularProgressIndicator(
                                color: Colors.white,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Center(
                        child: Text(
                          '박스를 누르면 카메라가 켜져요 · 길게 누르면 테스트용 QR',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const SectionLabel('최근 점검'),
                      for (final e in recent) ...[
                        Builder(
                          builder: (_) {
                            final latest = _repo.latestOf(e.id);

                            return EquipmentTile(
                              equipment: e,
                              subtitle: latest == null
                                  ? '${e.location} · 기록 없음'
                                  : '${e.location} · ${relativeDay(latest.date)}',
                              trailing: latest == null
                                  ? null
                                  : Pill.status(
                                      latest.status,
                                      count: latest.cautionItems.length,
                                    ),
                              onTap: () => _handleQr(e.id),
                            );
                          },
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 어두운 스캐너 박스
class _ScannerBox extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback? onLongPress; // 길게 누르기 (테스트용 QR)
  final bool active; // 카메라가 켜져 있으면 true
  final MobileScannerController? controller; // 카메라 (없으면 그림만)
  final void Function(BarcodeCapture)? onDetect; // QR 을 읽으면 호출

  const _ScannerBox({
    required this.onTap,
    this.onLongPress,
    this.active = false,
    this.controller,
    this.onDetect,
  });

  @override
  State<_ScannerBox> createState() => _ScannerBoxState();
}

class _ScannerBoxState extends State<_ScannerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 220.0;

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.scannerBg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
                children: [
                  if (widget.active && widget.controller != null) // 켜져 있을 때만 카메라 화면
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: MobileScanner(
                          controller: widget.controller!,
                          onDetect: widget.onDetect,
                        ),
                      ),
                    ),
                  const Positioned.fill(
                    child: CustomPaint(
                      painter: _CornerPainter(),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _anim,
                    builder: (_, _) => Positioned(
                      left: 20,
                      right: 20,
                      top: 20 + (size - 40) * _anim.value,
                      child: Container(
                        height: 2,
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.6),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!widget.active) // 카메라가 꺼져 있으면 안내
                    const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.qr_code_2,
                            size: 44,
                            color: Color(0xFF8A9099),
                          ),
                          SizedBox(height: 8),
                          Text(
                            '눌러서 카메라 켜기',
                            style: TextStyle(fontSize: 13, color: Color(0xFFB0B6BF)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// QR 가이드 모서리 4개
class _CornerPainter extends CustomPainter {
  const _CornerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const m = 16.0;
    const l = 26.0;

    final w = size.width;
    final h = size.height;

    // 좌상
    canvas.drawLine(const Offset(m, m), const Offset(m + l, m), p);
    canvas.drawLine(const Offset(m, m), const Offset(m, m + l), p);

    // 우상
    canvas.drawLine(Offset(w - m, m), Offset(w - m - l, m), p);
    canvas.drawLine(Offset(w - m, m), Offset(w - m, m + l), p);

    // 좌하
    canvas.drawLine(Offset(m, h - m), Offset(m + l, h - m), p);
    canvas.drawLine(Offset(m, h - m), Offset(m, h - m - l), p);

    // 우하
    canvas.drawLine(
      Offset(w - m, h - m),
      Offset(w - m - l, h - m),
      p,
    );
    canvas.drawLine(
      Offset(w - m, h - m),
      Offset(w - m, h - m - l),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}