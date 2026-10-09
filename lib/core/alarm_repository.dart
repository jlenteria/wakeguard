import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'alarm.dart';

/// Dart-side mirror of the alarm set.
///
/// The **native** stores are the source of truth for anything that must survive
/// a process death or a reboot; this cache exists so the settings UI can render
/// instantly and so an alarm is never silently lost between a write and the
/// next successful native schedule. Every mutation reschedules natively.
class AlarmRepository {
  static const _key = 'wakeguard.alarms.v2';
  static const _seedKey = 'wakeguard.seeded.v2';

  Future<List<Alarm>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException('Alarm mirror is not a list');
      final alarms = decoded
          .map((item) {
            try { return item is Map ? Alarm.fromJson(Map<String, Object?>.from(item)) : null; }
            catch (_) { return null; }
          })
          .whereType<Alarm>()
          .toList()
        ..sort((a, b) => a.minuteOfDay - b.minuteOfDay);
      return alarms;
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(List<Alarm> alarms) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _key,
      jsonEncode(alarms.map((a) => a.toJson()).toList()),
    );
    if (!saved) throw StateError('Alarm preferences could not be written');
  }

  Future<bool> hasSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_seedKey) ?? false;
  }

  Future<void> markSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_seedKey, true);
  }
}
