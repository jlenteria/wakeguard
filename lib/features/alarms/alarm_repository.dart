import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/alarm.dart';

/// Dart-side mirror of the alarm set; native stores are the source of truth,
/// while this cache keeps the UI instant and loses no alarm mid-write.
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
