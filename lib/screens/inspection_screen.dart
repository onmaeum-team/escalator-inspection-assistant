
import 'package:flutter/material.dart';

import '../models/inspection_item.dart';
import '../models/equipment.dart';
import '../controllers/equipment_repository.dart';
import '../widgets/common_app_header.dart';
import '../widgets/equipment_summary_card.dart';
import '../widgets/inspection_item_tile.dart';
import '../widgets/common_widgets.dart';
import 'voice_inspection_screen.dart';
import 'inspection_result_page.dart';
import 'hands_free_inspection_screen.dart';
import '../controllers/api_client.dart';


class InspectionScreen extends StatefulWidget {
  const InspectionScreen({super.key});

  @override
  State<InspectionScreen> createState() =>
      _InspectionScreenState();
}

class _InspectionScreenState extends State<InspectionScreen> {
  final EquipmentRepository _repo = EquipmentRepository.instance;

  String? _equipmentId;
  Equipment? _equipment;
  bool _routeArgumentsRead = false;

  // 점검 항목 목록
  final List<InspectionItem> inspectionItems = [
    InspectionItem(
      id: '1',
      title: '핸드레일',
      description: '점검 필요',
      cycle: '월간',
      isChecked: false,
    ),
    InspectionItem(
      id: '2',
      title: '스텝·라이저',
      description: '점검 필요',
      cycle: '월간',
      isChecked: true,
    ),
    InspectionItem(
      id: '3',
      title: '콤브',
      description: '점검 필요',
      cycle: '월간',
      isChecked: true,
    ),
    InspectionItem(
      id: '4',
      title: '스텝체인',
      description: '점검 필요',
      cycle: '3개월',
      isChecked: true,
    ),
    InspectionItem(
      id: '5',
      title: '구동체인',
      description: '점검 필요',
      cycle: '3개월',
      isChecked: false,
    ),
    InspectionItem(
      id: '6',
      title: '브레이크',
      description: '점검 필요',
      cycle: '3개월',
      isChecked: false,
    ),
  ];

  /// 라우트에서 전달받은 설비 ID로 설비 조회
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_routeArgumentsRead) return;
    _routeArgumentsRead = true;

    final arguments = ModalRoute.of(context)?.settings.arguments;

    if (arguments is String && arguments.isNotEmpty) {
      _equipmentId = arguments;
      _equipment = _repo.equipmentOf(arguments);
    }
  }

  /// 음성 점검 화면을 한 번 열고 결과 페이지로 이동
  Future<void> _startVoiceInspection() async {
    final equipmentId = _equipmentId;

    if (equipmentId == null || equipmentId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('설비 정보를 확인할 수 없습니다.'),
        ),
      );
      return;
    }

    // 보드 서버를 쓰면 핸즈프리 점검 화면으로 (항목은 서버가 검사기준 번호로 내려줌)
    if (ApiConfig.useServer) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => HandsFreeInspectionScreen(
            equipmentId: equipmentId,
            equipmentName: _equipment?.name ?? equipmentId,
          ),
        ),
      );
      return;
    }

    // 체크되지 않은 항목 중 첫 번째 항목 선택
    final pendingItems = inspectionItems
        .where((item) => !item.isChecked)
        .toList();

    // 점검할 항목이 없다면 결과 페이지로 바로 이동
    if (pendingItems.isEmpty) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          settings: RouteSettings(
            arguments: {
              'equipmentId': equipmentId,
              'inspectionItems': inspectionItems,
            },
          ),
          builder: (context) => const InspectionResultPage(),
        ),
      );
      return;
    }

    final item = pendingItems.first;

    // 음성 점검 화면은 한 번만 표시
    final completed = await Navigator.push<bool>(
      context,
      PageRouteBuilder<bool>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, animation, secondaryAnimation) {
          return VoiceInspectionScreen(
            equipmentId: equipmentId,
            itemId: item.id,
            itemName: item.title,
          );
        },
        transitionsBuilder: (
          context,
          animation,
          secondaryAnimation,
          child,
        ) {
          return child;
        },
      ),
    );

    if (!mounted || completed != true) return;

    // 음성 점검 완료 후 결과 페이지로 이동
    Navigator.pushReplacement(
      context,
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        settings: RouteSettings(
          arguments: {
            'equipmentId': equipmentId,
            'inspectionItems': inspectionItems,
          },
        ),
        pageBuilder: (context, animation, secondaryAnimation) {
          return const InspectionResultPage();
        },
        transitionsBuilder: (
          context,
          animation,
          secondaryAnimation,
          child,
        ) {
          return child;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final completedCount =
        inspectionItems.where((item) => item.isChecked).length;
    final totalCount = inspectionItems.length;

    final equipment = _equipment;

    // 실제 설비 위치
    final locationText = equipment == null
        ? (_equipmentId == null
            ? '설비 정보 없음'
            : '설비 ID: $_equipmentId')
        : (equipment.location.isEmpty
            ? '위치 미입력'
            : equipment.location);

    // 마지막 점검 정보
    final latest = _equipmentId == null
        ? null
        : _repo.latestOf(_equipmentId!);

    final lastInspectionText = latest == null
        ? '기록 없음'
        : '마지막 점검 ${relativeDay(latest.date)}';

    return Scaffold(
      backgroundColor: const Color(0xfff5f5f5),

      appBar: const CommonAppHeader(
        title: '점검 항목',
        subtitle: '오늘 수행할 항목입니다',
      ),

      body: Column(
        children: [
          // 분리한 설비 요약 카드
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: EquipmentSummaryCard(
              equipmentName: equipment?.name ??
                  (_equipmentId == null
                      ? '설비 정보 없음'
                      : '설비 ID: $_equipmentId'),
              locationText: locationText,
              lastInspectionText: lastInspectionText,
              completedCount: completedCount,
              totalCount: totalCount,
            ),
          ),

          const SizedBox(height: 24),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '이번 점검 대상',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // 점검 항목 목록
          Expanded(
            child: ScrollConfiguration(
              // 스크롤 끝에서 콘텐츠가 늘어나는 효과 제거
              behavior: ScrollConfiguration.of(context).copyWith(
                overscroll: false,
              ),
              child: ListView.separated(
                // 경계에서 늘어나거나 튕기는 효과 방지
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: inspectionItems.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final item = inspectionItems[index];

                  return InspectionItemTile(
                    item: item,
                    onChanged: (value) {
                      setState(() {
                        item.isChecked = value ?? false;
                      });

                      // TODO: 백엔드 상태 업데이트 연동
                    },
                  );
                },
              ),
            ),
          ),

          // 하단 음성 점검 시작 버튼
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _startVoiceInspection,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xff4c6ef5),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                '음성으로 점검 시작',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
