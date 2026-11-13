import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/equipment.dart';
import 'api_client.dart';
import 'on_device_db.dart';

/// QR 스캔 결과 종류
enum ScanResultType {
  registered, // 이미 내 담당 설비
  inDeviceDb, // 내 목록엔 없지만 서버/온디바이스 DB에 있음 → 등록하면 이력 가져옴
  unknown, // 어디에도 없는 완전 새 설비 → 직접 입력해서 등록
}

class ScanLookup {
  final String id;
  final ScanResultType type;
  final Equipment? equipment;
  final bool fromServer; // 서버에서 찾았는지 (안내 문구용)

  const ScanLookup(this.id, this.type, this.equipment, {this.fromServer = false});
}

/// 설비/이력 데이터 창구. 화면은 전부 여기서만 데이터를 가져감.
///
///  1) 서버(API) 먼저 시도 → 받은 데이터는 폰에 캐시
///  2) 서버 꺼짐/지하 기계실(네트워크 X) → 캐시 → 온디바이스 DB 순으로 사용
class EquipmentRepository extends ChangeNotifier {
  EquipmentRepository._();
  static final instance = EquipmentRepository._();

  static const _kMine = 'my_equipment_ids';
  static const _kCustom = 'custom_equipments';
  static const _kHistoryPrefix = 'histories_';

  final _api = ApiClient.instance;

  SharedPreferences? _prefs;
  bool _loaded = false;
  bool _online = false; // 마지막 서버 호출 성공 여부
  final List<String> _mineIds = [];
  final Map<String, Equipment> _custom = {}; // 온디바이스 DB에 없는 설비(서버/직접 입력)
  final Map<String, List<InspectionRecord>> _historyCache = {}; // 서버에서 받은 이력

  bool get isLoaded => _loaded;
  bool get isOnline => _online;

  Future<void> init() async {
    if (_loaded) return;
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('shared_preferences 사용 불가, 메모리 모드로 실행: $e');
      _prefs = null;
    }

    _mineIds
      ..clear()
      ..addAll(_prefs?.getStringList(_kMine) ?? OnDeviceDb.defaultMine);

    final customJson = _prefs?.getString(_kCustom);
    if (customJson != null) {
      for (final m in jsonDecode(customJson) as List) {
        final e = Equipment.fromJson(Map<String, dynamic>.from(m as Map));
        _custom[e.id] = e;
      }
    }

    // 지난번에 서버에서 받아둔 이력 (오프라인에서도 보이게)
    for (final id in _mineIds) {
      final cached = _prefs?.getString('$_kHistoryPrefix$id');
      if (cached == null) continue;
      _historyCache[id] = [
        for (final m in jsonDecode(cached) as List)
          InspectionRecord.fromJson(Map<String, dynamic>.from(m as Map)),
      ];
    }

    _loaded = true;
    notifyListeners();

    // 백그라운드로 내 담당 설비 이력 최신화
    for (final id in List.of(_mineIds)) {
      unawaited(syncHistory(id));
    }
  }

  // ───────────── 설비 목록 ─────────────

  Equipment? _resolve(String id) => _custom[id] ?? OnDeviceDb.find(id);
  Equipment? equipmentOf(String id) => _resolve(id); //id로 설비조회

  bool isMine(String id) => _mineIds.contains(id);

  List<Equipment> get myEquipments => [
        for (final id in _mineIds)
          if (_resolve(id) != null) _resolve(id)!,
      ];

  /// 최근 점검한 순서대로 [count]개
  List<Equipment> recentEquipments({int count = 3}) {
    final list = myEquipments;
    list.sort((a, b) {
      final da = latestOf(a.id)?.date;
      final db = latestOf(b.id)?.date;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
    return list.take(count).toList();
  }

  // ───────────── QR / NFC 스캔 ─────────────

  /// QR 내용 → escalatorId. 'esc-7' 같은 문자열이나 {"id":"esc-7"} JSON 둘 다 허용.
  static String parseQr(String raw) {
    final t = raw.trim();
    if (t.startsWith('{')) {
      try {
        final m = jsonDecode(t);
        if (m is Map) {
          final id = m['escalatorId'] ?? m['id'];
          if (id != null) return id.toString().toLowerCase();
        }
      } catch (_) {}
    }
    return t.toLowerCase();
  }

  /// GET /api/escalators/{escalatorId}  (실패 시 온디바이스 DB)
  Future<ScanLookup> lookup(String rawQr) async {
    final id = parseQr(rawQr);

    if (isMine(id)) {
      unawaited(syncHistory(id));
      return ScanLookup(id, ScanResultType.registered, _resolve(id));
    }

    try {
      final e = await _api.getEscalator(id);
      _online = true;
      await syncHistory(id); // 등록 전에 이력 건수를 보여주기 위해 미리 받아둠
      return ScanLookup(id, ScanResultType.inDeviceDb, e, fromServer: true);
    } on ApiNotFound {
      _online = true;
      return ScanLookup(id, ScanResultType.unknown, null);
    } on ApiOffline {
      _online = false;
      final inDb = OnDeviceDb.find(id);
      if (inDb != null) return ScanLookup(id, ScanResultType.inDeviceDb, inDb);
      return ScanLookup(id, ScanResultType.unknown, null);
    }
  }

  /// 내 담당 설비로 등록. 서버/온디바이스 DB 에 있는 설비면 이력이 바로 따라옴.
  /// 새 설비면 서버(보드)에도 등록 (POST /api/escalators). 서버가 안 되면 폰에만 저장.
  Future<void> register(Equipment e) async {
    if (OnDeviceDb.find(e.id) == null) _custom[e.id] = e;
    try {
      await _api.registerEscalator(e); // 보드에 등록
      _online = true;
    } on ApiError {
      _online = true; // 이미 보드에 있는 설비 (409) 등 → 그대로 진행
    } on ApiOffline {
      _online = false; // 보드 연결 안 됨 → 폰에만 저장
    }
    if (!_mineIds.contains(e.id)) _mineIds.insert(0, e.id);
    await _saveEquipments();
    final cached = _historyCache[e.id];
    if (cached != null) await _saveHistory(e.id, cached);
    notifyListeners();
  }

  /// 시연 전 원래 상태로 되돌리기
  Future<void> resetForTest() async {
    for (final id in _mineIds) {
      await _prefs?.remove('$_kHistoryPrefix$id');
    }
    _mineIds
      ..clear()
      ..addAll(OnDeviceDb.defaultMine);
    _custom.clear();
    _historyCache.clear();
    await _saveEquipments();
    notifyListeners();
  }

  Future<void> _saveEquipments() async {
    await _prefs?.setStringList(_kMine, _mineIds);
    await _prefs?.setString(
      _kCustom,
      jsonEncode([for (final e in _custom.values) e.toJson()]),
    );
  }

  Future<void> _saveHistory(String id, List<InspectionRecord> records) async {
    await _prefs?.setString(
      '$_kHistoryPrefix$id',
      jsonEncode([for (final r in records) r.toJson()]),
    );
  }

  // ───────────── 이력 / 주기 ─────────────

  /// GET /api/escalators/{escalatorId}/histories → 캐시 갱신.
  /// 서버가 안 되면 조용히 넘어감 (기존 캐시/온디바이스 DB 그대로 사용).
  Future<void> syncHistory(String id) async {
    try {
      final records = await _api.getHistories(id);
      _online = true;
      _historyCache[id] = records;
      if (isMine(id)) await _saveHistory(id, records);
      notifyListeners();
    } on ApiNotFound {
      _online = true;
    } on ApiOffline {
      _online = false;
    }
  }

  /// 서버에서 받은 이력 → 없으면 온디바이스 DB
  List<InspectionRecord> historyOf(String id) =>
      _historyCache[id] ?? OnDeviceDb.historyOf(id);

  InspectionRecord? latestOf(String id) {
    final h = historyOf(id);
    return h.isEmpty ? null : h.first;
  }

  /// 이번 달에 꼭 해야 하는 자체점검 항목 (지연된 것 먼저). 주기는 [별표 3] 자체점검기준
  List<DueItem> dueItems(String id, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final monthStart = DateTime(today.year, today.month, 1);
    final nextMonthStart = DateTime(today.year, today.month + 1, 1);
    final history = historyOf(id);

    final result = <DueItem>[];
    for (final item in CycleItem.all) {
      DateTime? last;
      for (final r in history) {
        if (r.checkedItems.contains(item.code) || r.checkedItems.contains(item.name)) { // 서버 이력은 번호, 예전 예시 이력은 이름
          last = r.date;
          break;
        }
      }
      if (last == null) {
        result.add(DueItem(item, null, DueLevel.overdue));
        continue;
      }
      final next = DateTime(last.year, last.month + item.cycleMonths, last.day);
      if (next.isBefore(monthStart)) {
        result.add(DueItem(item, last, DueLevel.overdue));
      } else if (next.isBefore(nextMonthStart)) {
        result.add(DueItem(item, last, DueLevel.thisMonth));
      }
    }
    result.sort((a, b) => a.level.index.compareTo(b.level.index));
    return result;
  }
}
