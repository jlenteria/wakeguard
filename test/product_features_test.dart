import 'package:flutter_test/flutter_test.dart';
import 'package:wakeguard/core/alarm.dart';
import 'package:wakeguard/core/history.dart';

void main() {
  test('skipping Friday preserves the weekday schedule and resumes Monday', () {
    final friday = DateTime(2026, 10, 9, 7);
    final alarm = Alarm(id: 'work', hour: 8, minute: 0, label: 'Work',
      weekdays: {1, 2, 3, 4, 5}, checkInMinutes: 5);
    final skipped = alarm.copyWith(skipUntilMillis: alarm.nextOccurrence(friday).millisecondsSinceEpoch);
    expect(skipped.nextOccurrence(friday), DateTime(2026, 10, 12, 8));
    expect(skipped.copyWith(skipUntilMillis: 0).nextOccurrence(friday), DateTime(2026, 10, 9, 8));
    final restored = Alarm.fromJson(skipped.toJson());
    expect(restored.checkInMinutes, 5);
    expect(restored.skipUntilMillis, skipped.skipUntilMillis);
    expect(restored.weekdays, alarm.weekdays);
  });

  test('a legacy alarm does not silently opt into check-ins', () {
    final alarm = Alarm.fromJson({'id': 'old', 'hour': 7, 'minute': 0});
    expect(alarm.checkInMinutes, 0);
    expect(alarm.skipUntilMillis, 0);
  });

  test('started and missed events never count as completed wake-ups', () {
    final now = DateTime(2026, 10, 12, 12);
    final entries = [
      {'at': now.millisecondsSinceEpoch, 'event': 'started'},
      {'at': now.millisecondsSinceEpoch, 'event': 'missed'},
    ];
    expect(computeWakeUpStats(entries, now: now).totalDays, 0);
  });

  test('a dismissal awaiting a check-in does not yet extend the streak', () {
    final now = DateTime(2026, 10, 12, 12);
    final dismissed = {'at': now.millisecondsSinceEpoch, 'event': 'dismissed', 'checkInMinutes': 5};
    expect(computeWakeUpStats([dismissed], now: now).streak, 0);
    final confirmed = {'at': now.millisecondsSinceEpoch, 'event': 'confirmed', 'method': 'checkin'};
    expect(computeWakeUpStats([confirmed, dismissed], now: now).streak, 1);
  });

  test('weekday alarms do not lose their streak on an unscheduled weekend', () {
    final now = DateTime(2026, 10, 12, 12);
    final entries = [
      {'at': DateTime(2026, 10, 12, 8).millisecondsSinceEpoch, 'event': 'dismissed'},
      {'at': DateTime(2026, 10, 9, 8).millisecondsSinceEpoch, 'event': 'dismissed'},
    ];
    final alarms = [Alarm(id: 'work', hour: 8, minute: 0, label: 'Work', weekdays: {1, 2, 3, 4, 5})];
    expect(computeWakeUpStats(entries, now: now, alarms: alarms).streak, 2);
    final missedThursday = {'at': DateTime(2026, 10, 8, 8).millisecondsSinceEpoch,
      'scheduledAt': DateTime(2026, 10, 8, 8).millisecondsSinceEpoch, 'event': 'missed'};
    expect(computeWakeUpStats([...entries, missedThursday], now: now, alarms: alarms).streak, 2);
  });
}
