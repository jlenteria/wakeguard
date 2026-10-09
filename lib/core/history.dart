import 'alarm.dart';

/// Wake-up statistics derived from native outcomes, never from starts alone.
class WakeUpStats {
  const WakeUpStats({
    required this.streak,
    required this.totalDays,
    required this.lastAt,
    required this.lastMethod,
  });

  /// Consecutive days, counting back from today (or yesterday when today has
  /// no dismissal yet), on which at least one alarm was dismissed.
  final int streak;

  /// Distinct days with at least one dismissal.
  final int totalDays;

  final DateTime? lastAt;
  final String? lastMethod;

  static const empty = WakeUpStats(
    streak: 0,
    totalDays: 0,
    lastAt: null,
    lastMethod: null,
  );
}

/// Counts distinct wake-up days and the current run.
///
/// History arrives newest-first as `{at, method}` maps. The streak tolerates
/// an empty today: someone who has not dismissed an alarm yet this morning has
/// not broken yesterday's run.
WakeUpStats computeWakeUpStats(
  List<Map<String, Object?>> entries, {
  DateTime? now,
  List<Alarm>? alarms,
}) {
  if (entries.isEmpty) return WakeUpStats.empty;
  final current = now ?? DateTime.now();

  final days = <DateTime>{};
  DateTime? lastAt;
  String? lastMethod;

  for (final entry in entries) {
    if (entry['event'] != null && entry['event'] != 'dismissed' && entry['event'] != 'confirmed') continue;
    if (entry['event'] == 'dismissed' && ((entry['checkInMinutes'] as num?)?.toInt() ?? 0) > 0 && entry['followUp'] != true) continue;
    final millis = entry['at'];
    if (millis is! num) continue;
    if (millis <= 0 || millis > current.millisecondsSinceEpoch) continue;
    final at = DateTime.fromMillisecondsSinceEpoch(millis.toInt());
    lastAt ??= at;
    lastMethod ??= entry['method'] as String?;
    days.add(DateTime(at.year, at.month, at.day));
  }
  if (days.isEmpty) return WakeUpStats.empty;

  final today = DateTime(current.year, current.month, current.day);
  final yesterday = DateTime(today.year, today.month, today.day - 1);

  var streak = 0;
  var cursor = days.contains(today) ? today : yesterday;
  // A day with no dismissal only ends the streak if it is in the past: today
  // is still in progress.
  final earliest = days.reduce((a, b) => a.isBefore(b) ? a : b);
  while (!cursor.isBefore(earliest)) {
    if (days.contains(cursor)) {
      streak++;
    } else {
      final observed = entries.any((entry) {
        final raw = entry['scheduledAt'];
        if (raw is! num) return false;
        final at = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
        return at.year == cursor.year && at.month == cursor.month && at.day == cursor.day;
      });
      final scheduled = alarms == null || !alarms.any((a) => a.enabled && a.isRepeating) || alarms.any((alarm) =>
          alarm.enabled && alarm.isRepeating && alarm.isScheduledFor(cursor) &&
          (alarm.createdAt == null || !DateTime(alarm.createdAt!.year, alarm.createdAt!.month, alarm.createdAt!.day).isAfter(cursor)) &&
          !(alarm.skipUntilMillis > 0 && DateTime.fromMillisecondsSinceEpoch(alarm.skipUntilMillis).year == cursor.year &&
            DateTime.fromMillisecondsSinceEpoch(alarm.skipUntilMillis).month == cursor.month &&
            DateTime.fromMillisecondsSinceEpoch(alarm.skipUntilMillis).day == cursor.day));
      if (observed || scheduled) break;
    }
    cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
  }

  return WakeUpStats(
    streak: streak,
    totalDays: days.length,
    lastAt: lastAt,
    lastMethod: lastMethod,
  );
}
