import 'package:flutter/material.dart';

import '../constants/app_theme.dart';
import '../controllers/equipment_repository.dart';
import '../models/equipment.dart';
import '../widgets/common_widgets.dart';
import '../widgets/common_app_header.dart';
import 'hands_free_inspection_screen.dart'; // 지난 점검 상세 화면 (InspectionDetailScreen)

/// 프레임 2 (왼쪽) — 점검 기록: 내 담당 설비 검색 + 목록
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _repo = EquipmentRepository.instance;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const CommonAppHeader(
          title: '점검 기록',
          subtitle: '설비별 점검 기록을 확인합니다',
          showBackButton: false,
          showOfflineBadge: true,
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: _repo,
            builder: (context, _) {
              final results = _repo.myEquipments
                  .where((e) =>
                      _query.isEmpty ||
                      e.name.contains(_query) ||
                      e.location.contains(_query))
                  .toList();

              return ScrollConfiguration(
                // 스크롤 끝에서 콘텐츠가 늘어나는 효과 제거
                behavior: ScrollConfiguration.of(context).copyWith(
                  overscroll: false,
                ),
                child: ListView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  children: [
                  SearchField(
                    hint: '에스컬레이터 검색',
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                  const SizedBox(height: 20),
                  SectionLabel(_query.isEmpty
                      ? '내 담당 설비 ${results.length}대'
                      : '검색 결과'),
                  if (results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text('검색 결과가 없습니다',
                            style: TextStyle(color: AppColors.textSecondary)),
                      ),
                    ),
                  for (final e in results) ...[
                    EquipmentTile(
                      equipment: e,
                      subtitle: _subtitle(e),
                      trailing: Pill.due(_repo.dueItems(e.id)),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => HistoryDetailScreen(equipment: e)),
                      ),
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
    );
  }

  String _subtitle(Equipment e) {
    final latest = _repo.latestOf(e.id);
    final where = e.location.isEmpty ? '위치 미입력' : e.location;
    return latest == null
        ? '$where · 기록 없음'
        : '$where · 최근 ${relativeDay(latest.date)}';
  }
}

/// 프레임 2 (오른쪽) — N호기 이력: 이번 달 필수 항목 + 타임라인
class HistoryDetailScreen extends StatefulWidget {
  final Equipment equipment;

  const HistoryDetailScreen({super.key, required this.equipment});

  @override
  State<HistoryDetailScreen> createState() => _HistoryDetailScreenState();
}

class _HistoryDetailScreenState extends State<HistoryDetailScreen> {
  final _repo = EquipmentRepository.instance;
  String _query = '';
  bool _cautionOnly = false; // '주의만' 필터 칩

  @override
  void initState() {
    super.initState();
    // GET /api/escalators/{escalatorId}/histories (서버 안 되면 캐시/온디바이스 DB)
    _repo.syncHistory(widget.equipment.id);
  }

  /// "지난 스텝체인 결과" → 스텝체인을 점검한 기록만
  /// "주의" → 주의 판정 기록만
  bool _matches(InspectionRecord r) {
    if (_cautionOnly && r.status != InspectionStatus.caution) return false;
    final q = _query;
    if (q.isEmpty) return true;
    if (q.contains('주의') && r.status == InspectionStatus.caution) return true;
    return r.checkedItems.any((n) => q.contains(n) || n.contains(q)) ||
        r.cautionItems.any((n) => q.contains(n) || n.contains(q));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _repo,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final e = widget.equipment;
    final all = _repo.historyOf(e.id);
    final records = all.where(_matches).toList();
    final due = _repo.dueItems(e.id);
    final cautionCount =
        all.where((r) => r.status == InspectionStatus.caution).length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            CommonAppHeader(
              title: '${e.shortName} 이력',
              subtitle: e.spec == null
                  ? '최근 점검 기록을 확인합니다'
                  : '승강기번호 ${e.spec!.elevatorNo} · ${e.location}',
              onBackPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: RefreshIndicator(
                // 아래로 당기면 서버에서 다시 받기
                onRefresh: () => _repo.syncHistory(e.id),
                child: ScrollConfiguration(
                  // 당겨서 새로고침 기능은 유지하고 늘어나는 시각 효과만 제거
                  behavior: ScrollConfiguration.of(context).copyWith(
                    overscroll: false,
                  ),
                  child: ListView(
                    physics: const ClampingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    children: [
                  EquipmentSpecCard(spec: e.spec),
                  const SizedBox(height: 12),
                  // 누락 방지: 이번 달 필수 항목
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.event_note,
                                size: 16, color: AppColors.primary),
                            SizedBox(width: 6),
                            Text('이번 달 필수 점검',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (all.isEmpty)
                          const Text('점검 이력이 없어요. 첫 점검에서 전체 항목을 확인하세요.',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary))
                        else
                          DueChips(items: due),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // TODO: 마이크 버튼 → controllers/ 의 STT 결과를 이 검색창에 넣기
                  SearchField(
                    hint: "음성 검색: '지난 스텝체인 결과'",
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _FilterChip(
                        label: '전체 ${all.length}',
                        selected: !_cautionOnly,
                        onTap: () => setState(() => _cautionOnly = false),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: '주의만 $cautionCount',
                        selected: _cautionOnly,
                        danger: true,
                        onTap: () => setState(() => _cautionOnly = true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (records.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(
                            all.isEmpty ? '아직 점검 기록이 없어요' : '조건에 맞는 기록이 없어요',
                            style: const TextStyle(
                                color: AppColors.textSecondary)),
                      ),
                    ),
                  for (var i = 0; i < records.length; i++)
                    _TimelineItem(
                      record: records[i],
                      isLast: i == records.length - 1,
                    ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context)
                      .pushNamed('/inspect', arguments: e.id),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('이 설비 점검 시작',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineItem extends StatelessWidget {
  final InspectionRecord record;
  final bool isLast;

  const _TimelineItem({required this.record, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final isNormal = record.status == InspectionStatus.normal;
    final dotColor = isNormal ? AppColors.normal : AppColors.danger;
    final badgeLabel = isNormal
        ? '전체 정상'
        : '주의 ${record.cautionItems.length} · ${record.cautionItems.join(', ')}';

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 점 + 세로선
          SizedBox(
            width: 20,
            child: Column(
              children: [
                const SizedBox(height: 18),
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: dotColor, shape: BoxShape.circle),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(width: 1.5, color: AppColors.border),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AppCard(
                onTap: record.inspectionId == null // 점검 번호가 있으면 상세 화면으로
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => InspectionDetailScreen(
                            inspectionId: record.inspectionId!,
                            title: formatDate(record.date),
                          ),
                        )),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formatDate(record.date),
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 4),
                    Text(
                        '점검자 · ${record.inspector} · ${record.durationMinutes}분 소요',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                    const SizedBox(height: 2),
                    Text('점검 항목 · ${record.checkedItems.join(', ')}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                    if (record.note != null && record.note!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text('특이사항 · ${record.note}',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textPrimary)),
                    ],
                    const SizedBox(height: 8),
                    Pill.status(record.status, label: badgeLabel),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 전체 / 주의만 필터 칩
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool danger;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = danger ? AppColors.danger : AppColors.primary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? accent : AppColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? accent : AppColors.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.textSecondary)),
      ),
    );
  }
}
