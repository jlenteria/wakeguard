import 'alarm.dart';

/// Shared by the streak and its weekday display. A dismissal awaiting a
/// configured check-in does not count until confirmed or its follow-up is done.
bool isCompletedWakeUpEvent(Map<String, Object?> entry) {
  final event = entry['event'];
  if (event != null && event != 'dismissed' && event != 'confirmed') {
    return false;
  }
  return !(event == 'dismissed' &&
      ((entry['checkInMinutes'] as num?)?.toInt() ?? 0) > 0 &&
      entry['followUp'] != true);
}

/// Wake-up statistics derived from native outcomes, never from starts alone.
class WakeUpStats {
  const WakeUpStats({
    required this.streak,
    required this.totalDays,
    required this.lastAt,
    required this.lastMethod,
  });

  /// Consecutive days with a dismissal, from today or yesterday back.
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

/// Counts distinct wake-up days and streak; an empty today does not break it.
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
    if (!isCompletedWakeUpEvent(entry)) continue;
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
  // A missing dismissal only ends the streak if the day is past; today is ongoing.
  final earliest = days.reduce((a, b) => a.isBefore(b) ? a : b);
  while (!cursor.isBefore(earliest)) {
    if (days.contains(cursor)) {
      streak++;
    } else {
      final observed = entries.any((entry) {
        final raw = entry['scheduledAt'];
        if (raw is! num) return false;
        final at = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
        return at.year == cursor.year &&
            at.month == cursor.month &&
            at.day == cursor.day;
      });
      final scheduled =
          alarms == null ||
          !alarms.any((a) => a.enabled && a.isRepeating) ||
          alarms.any(
            (alarm) =>
                alarm.enabled &&
                alarm.isRepeating &&
                alarm.isScheduledFor(cursor) &&
                (alarm.createdAt == null ||
                    !DateTime(
                      alarm.createdAt!.year,
                      alarm.createdAt!.month,
                      alarm.createdAt!.day,
                    ).isAfter(cursor)) &&
                !(alarm.skipUntilMillis > 0 &&
                    DateTime.fromMillisecondsSinceEpoch(
                          alarm.skipUntilMillis,
                        ).year ==
                        cursor.year &&
                    DateTime.fromMillisecondsSinceEpoch(
                          alarm.skipUntilMillis,
                        ).month ==
                        cursor.month &&
                    DateTime.fromMillisecondsSinceEpoch(
                          alarm.skipUntilMillis,
                        ).day ==
                        cursor.day),
          );
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
