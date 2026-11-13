/// 점검 결과 상태
enum InspectionStatus { normal, caution }

/// 설비 (에스컬레이터 등)
class Equipment {
  final String id; // QR/NFC 에 들어있는 값. 예: esc-3
  final String name; // 예: 3호기 에스컬레이터
  final String location; // 예: B동 2층
  final EquipmentSpec? spec; // 기본제원 (정기검사기준 3.1)

  const Equipment({
    required this.id,
    required this.name,
    required this.location,
    this.spec,
  });

  /// '3호기 에스컬레이터' → '3호기'
  String get shortName => name.replaceAll(' 에스컬레이터', '');

  /// API 응답(escalatorId) / 로컬 저장(id) 둘 다 읽음
  factory Equipment.fromJson(Map<String, dynamic> json) => Equipment(
        id: (json['escalatorId'] ?? json['id']).toString(),
        name: json['name'] as String? ?? '이름 없음',
        location: json['location'] as String? ?? '',
        spec: json['spec'] is Map
            ? EquipmentSpec.fromJson(Map<String, dynamic>.from(json['spec'] as Map))
            : null,
      );

  Map<String, dynamic> toJson() => {
        'escalatorId': id,
        'name': name,
        'location': location,
        if (spec != null) 'spec': spec!.toJson(),
      };
}

/// 기본제원 — 「에스컬레이터 정기검사기준」 3.1 항목
/// (승강기안전종합정보망 정보와 일치해야 하는 값들)
class EquipmentSpec {
  final String elevatorNo; // 승강기번호
  final String? certNo; // 승강기 인증번호
  final String? model; // 모델명/제품명
  final String? manufacturer; // 제조업체명
  final double? floorHeightM; // 층고 (m)
  final int? inclineDeg; // 경사도 (°)
  final int? nominalWidthMm; // 공칭폭 (mm)
  final double? ratedSpeed; // 정격속도 (m/s)
  final String? driveType; // 구동 운전방식: 인버터식 / Y-△식 / 직결식
  final String? lubrication; // 디딤판 체인 윤활: 자동식 / 수동식
  final List<String> notApplicable; // 이 설비에서 '해당없음'인 항목 (설비마다 고정)

  const EquipmentSpec({
    required this.elevatorNo,
    this.certNo,
    this.model,
    this.manufacturer,
    this.floorHeightM,
    this.inclineDeg,
    this.nominalWidthMm,
    this.ratedSpeed,
    this.driveType,
    this.lubrication,
    this.notApplicable = const [],
  });

  factory EquipmentSpec.fromJson(Map<String, dynamic> j) => EquipmentSpec(
        elevatorNo: '${j['elevatorNo'] ?? ''}',
        certNo: j['certNo'] as String?,
        model: j['model'] as String?,
        manufacturer: j['manufacturer'] as String?,
        floorHeightM: (j['floorHeightM'] as num?)?.toDouble(),
        inclineDeg: (j['inclineDeg'] as num?)?.toInt(),
        nominalWidthMm: (j['nominalWidthMm'] as num?)?.toInt(),
        ratedSpeed: (j['ratedSpeed'] as num?)?.toDouble(),
        driveType: j['driveType'] as String?,
        lubrication: j['lubrication'] as String?,
        notApplicable: List<String>.from(j['notApplicable'] ?? const []),
      );

  Map<String, dynamic> toJson() => {
        'elevatorNo': elevatorNo,
        'certNo': certNo,
        'model': model,
        'manufacturer': manufacturer,
        'floorHeightM': floorHeightM,
        'inclineDeg': inclineDeg,
        'nominalWidthMm': nominalWidthMm,
        'ratedSpeed': ratedSpeed,
        'driveType': driveType,
        'lubrication': lubrication,
        'notApplicable': notApplicable,
      };
}

/// 설비 1건에 대한 점검 기록 (이력 타임라인 1칸)
class InspectionRecord {
  final DateTime date;
  final String inspector;
  final int durationMinutes;
  final InspectionStatus status;
  final List<String> cautionItems; // 주의 판정 항목. 예: ['스텝체인']
  final List<String> checkedItems; // 이번에 점검한 항목 (주기 계산에 사용)
  final String? inspectionId; // 결과 화면(/api/inspections/{id}) 연결용
  final String? note; // 특이사항

  const InspectionRecord({
    required this.date,
    required this.inspector,
    required this.durationMinutes,
    required this.status,
    this.cautionItems = const [],
    this.checkedItems = const [],
    this.inspectionId,
    this.note,
  });

  /// API 응답(inspectedAt, "CAUTION") / 로컬 저장(date, "caution") 둘 다 읽음
  factory InspectionRecord.fromJson(Map<String, dynamic> json) =>
      InspectionRecord(
        date: DateTime.parse((json['inspectedAt'] ?? json['date']) as String),
        inspector: json['inspector'] as String? ?? '',
        durationMinutes: (json['durationMinutes'] as num?)?.toInt() ?? 0,
        status: '${json['status']}'.toLowerCase() == 'caution'
            ? InspectionStatus.caution
            : InspectionStatus.normal,
        cautionItems: List<String>.from(json['cautionItems'] ?? const []),
        checkedItems: List<String>.from(json['checkedItems'] ?? const []),
        inspectionId: json['inspectionId']?.toString(),
        note: json['note'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'inspectionId': inspectionId,
        'inspectedAt': date.toIso8601String(),
        'inspector': inspector,
        'durationMinutes': durationMinutes,
        'status': status.name.toUpperCase(),
        'cautionItems': cautionItems,
        'checkedItems': checkedItems,
        'note': note,
      };
}

/// 주기별 점검 항목 (1 / 3 / 6 / 12개월)
/// ※ 팀원의 InspectionItem(프레임 3 체크리스트)과 이름(title)을 맞춰 쓰면 됨.
/// 자체점검 주기가 있는 항목. [별표 3] 자체점검기준 3. 에스컬레이터의 점검주기(회/월)를
/// 정기검사기준 70개 항목 번호에 연결한 것 (서버 pipeline.py 의 SELF_CYCLE 과 같은 내용)
class CycleItem {
  final String code; // 검사기준 번호. 예: 3.6.2
  final String name; // 항목 이름
  final int cycleMonths; // 1 = 매달, 3 = 3개월마다, 6 = 6개월마다

  const CycleItem(this.code, this.name, this.cycleMonths);

  String get cycleLabel => switch (cycleMonths) {
        1 => '월간',
        12 => '연간',
        _ => '$cycleMonths개월',
      };

  static const all = [
    CycleItem('3.2.1', '안전표시', 3),
    CycleItem('3.2.2', '수동핸들 지침', 3),
    CycleItem('3.2.3', '기계류 접근 출입문 안내', 3),
    CycleItem('3.2.4', '비상정지장치 색상', 3),
    CycleItem('3.2.5', '유지보수 및 점검 중 접근방지 수단', 3),
    CycleItem('3.2.6', '자동 기동 운행방향 표시장치', 1),
    CycleItem('3.3.1', '접근금지장치', 3),
    CycleItem('3.3.2', '미끄럼방지장치', 3),
    CycleItem('3.3.3', '장애물로부터의 보호', 1),
    CycleItem('3.3.4', '방화셔터 인근의 에스컬레이터', 6),
    CycleItem('3.3.5', '연속되는 에스컬레이터 사이 공간', 3),
    CycleItem('3.3.6', '손잡이 바깥쪽 건물난간', 1),
    CycleItem('3.3.7', '조명 및 콘센트', 1),
    CycleItem('3.4.1', '조명 절연저항', 1),
    CycleItem('3.4.2', '접지, 전동기 절연저항 및 배선', 3),
    CycleItem('3.5.1', '디딤판 주행안내', 1),
    CycleItem('3.5.2', '스텝/팔레트 사이의 틈새', 1),
    CycleItem('3.5.3', '디딤판과 스커트 사이 틈새', 1),
    CycleItem('3.5.4', '트레드 홈에 맞물리는 콤의 깊이', 1),
    CycleItem('3.5.5', '손잡이 외형 및 가이드/덮개', 3),
    CycleItem('3.5.6', '손잡이 틈새', 3),
    CycleItem('3.6.1', '유지점검 및 보수용 정지스위치', 1),
    CycleItem('3.6.2', '비상정지장치', 1),
    CycleItem('3.6.3', '과부하(전류 증가)', 1),
    CycleItem('3.6.4', '과부하(온도 증가)', 1),
    CycleItem('3.6.5', '과속감지', 1),
    CycleItem('3.6.6', '의도되지 않은 운행 방향의 역전', 1),
    CycleItem('3.6.7', '보조브레이크의 미-작동 감지', 1),
    CycleItem('3.6.8', '인장장치의 과도한 움직임', 1),
    CycleItem('3.6.9', '디딤판체인의 파단과 과도한 늘어짐', 1),
    CycleItem('3.6.10', '콤 안전장치', 1),
    CycleItem('3.6.11', '연속 에스컬레이터 및 무빙워크의 추가 정지장치', 1),
    CycleItem('3.6.12', '손잡이 인입구 장치', 1),
    CycleItem('3.6.13', '스텝/팔레트 처짐 감지 장치', 1),
    CycleItem('3.6.14', '스텝/팔레트 누락 감지 장치', 1),
    CycleItem('3.6.15', '브레이크의 미-작동 감지장치', 1),
    CycleItem('3.6.16', '손잡이의 속도 편차 감지', 1),
    CycleItem('3.6.17', '점검용 덮개 열림', 1),
    CycleItem('3.6.18', '과도한 정지거리', 1),
    CycleItem('3.6.20', '수동핸들의 설치 감지', 1),
    CycleItem('3.6.21', '점검운전 제어장치의 정지장치 작동 감지', 1),
    CycleItem('3.6.22', '쇼핑 카트 및 수하물 카트 진입방지대 감지', 1),
    CycleItem('3.7.1', '점검운전 제어장치', 3),
    CycleItem('3.7.2', '수동 기동운전', 3),
    CycleItem('3.7.3', '자동 기동 운전', 1),
    CycleItem('3.8.1', '디딤판 주행', 1),
    CycleItem('3.8.2', '손잡이 주행', 1),
    CycleItem('3.8.3', '스커트 및 스커트 디플렉터', 3),
    CycleItem('3.8.4', '기어오름방지장치', 1),
    CycleItem('3.8.5', '접근금지장치', 1),
    CycleItem('3.8.6', '미끄럼방지장치', 1),
    CycleItem('3.8.7', '안전 보호판', 1),
    CycleItem('3.8.8', '쇼핑카트', 1),
    CycleItem('3.8.9', '옥외용 에스컬레이터의 추가요건', 6),
    CycleItem('3.9.1', '속도, 전류 및 정지거리', 1),
    CycleItem('3.9.2', '보조브레이크', 1),
  ];
}

enum DueLevel {
  overdue, // 지난 주기를 놓침 (빨강)
  thisMonth, // 이번 달에 해야 함 (파랑)
}

/// 이번에 꼭 해야 하는 점검 항목 (누락 방지 안내)
class DueItem {
  final CycleItem item;
  final DateTime? lastDone; // null = 기록 없음
  final DueLevel level;

  const DueItem(this.item, this.lastDone, this.level);
}
