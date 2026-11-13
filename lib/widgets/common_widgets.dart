import 'package:flutter/material.dart';

import '../constants/app_theme.dart';
import '../models/equipment.dart';

// ───────────────────────── 날짜 표시 헬퍼 ─────────────────────────

String formatDate(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

/// 오늘 / 어제 / 3일 전 / 2주 전 / 2026.06.15
String relativeDay(DateTime d) {
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day)
      .difference(DateTime(d.year, d.month, d.day))
      .inDays;
  if (days <= 0) return '오늘';
  if (days == 1) return '어제';
  if (days < 7) return '$days일 전';
  if (days < 31) return '${days ~/ 7}주 전';
  return formatDate(d);
}

// ───────────────────────── 헤더 ─────────────────────────

// /// 상단 제목 + 부제목 (뒤로가기 버튼, 오른쪽 위젯 선택)
// class PageHeader extends StatelessWidget {
//   final String title;
//   final String subtitle;
//   final VoidCallback? onBack;
//   final Widget? trailing;

//   const PageHeader({
//     super.key,
//     required this.title,
//     required this.subtitle,
//     this.onBack,
//     this.trailing,
//   });

//   @override
//   Widget build(BuildContext context) {
//     return Container(
//       color: AppColors.surface,
//       padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
//       child: Row(
//         children: [
//           if (onBack != null) ...[
//             Material(
//               color: AppColors.toggleBg,
//               shape: const CircleBorder(),
//               child: InkWell(
//                 customBorder: const CircleBorder(),
//                 onTap: onBack,
//                 child: const Padding(
//                   padding: EdgeInsets.all(8),
//                   child: Icon(Icons.chevron_left,
//                       size: 20, color: AppColors.textSecondary),
//                 ),
//               ),
//             ),
//             const SizedBox(width: 12),
//           ],
//           Expanded(
//             child: Column(
//               crossAxisAlignment: CrossAxisAlignment.start,
//               children: [
//                 Text(title,
//                     style: const TextStyle(
//                         fontSize: 22,
//                         fontWeight: FontWeight.w700,
//                         color: AppColors.textPrimary)),
//                 const SizedBox(height: 2),
//                 Text(subtitle,
//                     style: const TextStyle(
//                         fontSize: 12, color: AppColors.textSecondary)),
//               ],
//             ),
//           ),
//           ?trailing,
//         ],
//       ),
//     );
//   }
// }

/// 오른쪽 위 '● 온디바이스' 표시 (네트워크 없이 동작 중)
// class OnDeviceChip extends StatelessWidget {
//   const OnDeviceChip({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return Container(
//       padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
//       decoration: BoxDecoration(
//         color: AppColors.primaryBg,
//         borderRadius: BorderRadius.circular(999),
//       ),
//       child: const Row(
//         mainAxisSize: MainAxisSize.min,
//         children: [
//           Icon(Icons.memory, size: 12, color: AppColors.primary),
//           SizedBox(width: 4),
//           Text('온디바이스',
//               style: TextStyle(
//                   fontSize: 10,
//                   fontWeight: FontWeight.w600,
//                   color: AppColors.primary)),
//         ],
//       ),
//     );
//   }
// }

// ───────────────────────── 배지 ─────────────────────────

/// 둥근 배지
class Pill extends StatelessWidget {
  final String label;
  final Color color;
  final Color background;

  // 개별 배지에서 지정하지 않으면 적용되는 기본 스타일
  final EdgeInsetsGeometry? padding;
  final double? fontSize;
  final double? borderRadius;

  static const EdgeInsetsGeometry defaultPadding =
      EdgeInsets.symmetric(horizontal: 12, vertical: 6);

  static const double defaultFontSize = 12;
  static const double defaultBorderRadius = 999;

  const Pill({
    super.key,
    required this.label,
    required this.color,
    required this.background,
    this.padding,
    this.fontSize,
    this.borderRadius,
  });

  /// 정상 / 주의 N
  factory Pill.status(
    InspectionStatus status, {
    String? label,
    int count = 0,
  }) {
    final normal = status == InspectionStatus.normal;

    return Pill(
      label: label ?? (normal ? '정상' : '주의 $count'),
      color: normal ? AppColors.normal : AppColors.warning,
      background: normal ? AppColors.normalBg : AppColors.warningBg,
    );
  }

  /// 점검 결과 상태를 공통 배지로 변환
  factory Pill.inspectionStatus(String rawStatus) {
    final normalizedStatus = rawStatus.replaceAll(
      RegExp(r'\s+'),
      '',
    );

    switch (normalizedStatus) {
      case '양호':
      case '정상':
        return Pill(
          label: '정상',
          color: AppColors.normal,
          background: AppColors.normalBg,
        );

      case '주의관찰':
      case '주의':
        return Pill(
          label: '주의',
          color: AppColors.warning,
          background: AppColors.warningBg,
        );

      case '수리요함':
      case '수리필요':
      case '수리':
        return Pill(
          label: '수리',
          color: AppColors.danger,
          background: AppColors.dangerBg,
        );

      default:
        return Pill(
          label: rawStatus,
          color: AppColors.warning,
          background: AppColors.warningBg,
        );
    }
  }

  /// 점검 주기 배지
  factory Pill.cycle(String cycle) {
    final isMonthly = cycle == '월간';

    return Pill(
      label: cycle,
      color: isMonthly
          ? const Color(0xff4c6ef5)
          : const Color(0xffa55eea),
      background: isMonthly
          ? const Color(0xffe8f0fe)
          : const Color(0xfff3e8ff),
    );
  }

  /// 이번 달 필수 개수 (지연 있으면 빨강)
  static Widget? due(List<DueItem> due) {
    if (due.isEmpty) return null;

    final overdue =
        due.where((d) => d.level == DueLevel.overdue).length;

    return overdue > 0
        ? Pill(
            label: '지연 $overdue',
            color: AppColors.danger,
            background: AppColors.dangerBg,
          )
        : Pill(
            label: '이번 달 ${due.length}',
            color: AppColors.primary,
            background: AppColors.primaryBg,
          );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? defaultPadding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(
          borderRadius ?? defaultBorderRadius,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: fontSize ?? defaultFontSize,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 이번에 꼭 해야 하는 점검 항목들 (누락 방지)
class DueChips extends StatelessWidget {
  final List<DueItem> items;

  const DueChips({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Row(
        children: [
          Icon(Icons.check_circle, size: 16, color: AppColors.normal),
          SizedBox(width: 6),
          Text('이번 달 필수 항목을 모두 완료했어요',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ],
      );
    }
    const maxShow = 6; // 칩이 너무 많으면 6개만 보이고 나머지는 '외 n개'
    final shown = items.take(maxShow).toList();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (items.length > maxShow)
          Pill(
            label: '이번 달 ${items.length}개 항목',
            color: AppColors.textPrimary,
            background: AppColors.border,
          ),
        for (final d in shown)
          Pill(
            label: d.level == DueLevel.overdue
                ? '${d.item.name} · ${d.lastDone == null ? '기록 없음' : '지연'}'
                : '${d.item.name} · ${d.item.cycleLabel}',
            color: d.level == DueLevel.overdue
                ? AppColors.danger
                : AppColors.primary,
            background: d.level == DueLevel.overdue
                ? AppColors.dangerBg
                : AppColors.primaryBg,
          ),
      ],
    );
  }
}

// ───────────────────────── 기본제원 ─────────────────────────

/// 기본제원 카드 (정기검사기준 3.1). 탭하면 펼쳐짐.
class EquipmentSpecCard extends StatefulWidget {
  final EquipmentSpec? spec;
  final bool initiallyExpanded;

  const EquipmentSpecCard({
    super.key,
    required this.spec,
    this.initiallyExpanded = false,
  });

  @override
  State<EquipmentSpecCard> createState() => _EquipmentSpecCardState();
}

class _EquipmentSpecCardState extends State<EquipmentSpecCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final s = widget.spec;
    if (s == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text('기본제원 정보 없음 · 승강기번호를 확인해 주세요',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      );
    }

    String fmt(num? v, String unit) => v == null ? '-' : '$v$unit';
    final rows = <(String, String)>[
      ('인증번호', s.certNo ?? '-'),
      ('제조사', s.manufacturer ?? '-'),
      ('층고', fmt(s.floorHeightM, ' m')),
      ('경사도', fmt(s.inclineDeg, '°')),
      ('공칭폭', fmt(s.nominalWidthMm, ' mm')),
      ('정격속도', fmt(s.ratedSpeed, ' m/s')),
      ('구동방식', s.driveType ?? '-'),
      ('체인 윤활', s.lubrication ?? '-'),
    ];

    return Material(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.badge_outlined,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Text('승강기번호 ${s.elevatorNo}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        '${s.model ?? ''} · ${fmt(s.ratedSpeed, ' m/s')}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: AppColors.textSecondary),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 10),
                for (final (label, value) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 72,
                          child: Text(label,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                        ),
                        Expanded(
                          child: Text(value,
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.textPrimary)),
                        ),
                      ],
                    ),
                  ),
                if (s.notApplicable.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('해당없음 항목 (점검 시 자동 제외)',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final n in s.notApplicable)
                        Pill(
                            label: n,
                            color: AppColors.textSecondary,
                            background: AppColors.toggleBg),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 카드 / 목록 ─────────────────────────

/// 흰색 둥근 카드
class AppCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 설비 카드 (스캔 화면 '최근 점검' / 기록 화면 목록 공용)
class EquipmentTile extends StatelessWidget {
  final Equipment equipment;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const EquipmentTile({
    super.key,
    required this.equipment,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(equipment.name,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 검색창
class SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String>? onChanged;
  final TextEditingController? controller;

  const SearchField(
      {super.key, required this.hint, this.onChanged, this.controller});

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c),
        );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle:
            const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        prefixIcon: const Icon(Icons.search,
            size: 18, color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: border(AppColors.border),
        enabledBorder: border(AppColors.border),
        focusedBorder: border(AppColors.primary),
      ),
    );
  }
}

/// 섹션 라벨 ('최근 점검', '검색 결과')
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary)),
      );
}
