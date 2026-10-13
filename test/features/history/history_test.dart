import 'package:flutter_test/flutter_test.dart';
import 'package:wakeguard/models/wake_up_stats.dart';

List<Map<String, Object?>> _entries(List<DateTime> days) => [
  for (final day in days)
    {
      'at': DateTime(day.year, day.month, day.day, 7).millisecondsSinceEpoch,
      'method': 'face',
    },
];

void main() {
  group('computeWakeUpStats', () {
    final now = DateTime(2026, 10, 8, 9); // Thursday

    test('empty history is empty stats', () {
      final stats = computeWakeUpStats(const [], now: now);

      expect(stats.streak, 0);
      expect(stats.totalDays, 0);
      expect(stats.lastAt, isNull);
      expect(stats.lastMethod, isNull);
    });

    test('counts distinct days, not dismissals', () {
      final today = DateTime(2026, 10, 8);
      final stats = computeWakeUpStats([
        ..._entries([today, today]),
        ..._entries([today.subtract(const Duration(days: 1))]),
      ], now: now);

      expect(stats.totalDays, 2);
      expect(stats.streak, 2);
    });

    test('a still-open today does not break yesterday\'s streak', () {
      final stats = computeWakeUpStats(
        _entries([DateTime(2026, 10, 7)]),
        now: now,
      );

      expect(stats.streak, 1);
    });

    test('a gap in the past breaks the streak', () {
      final stats = computeWakeUpStats(
        _entries([
          DateTime(2026, 10, 6),
          DateTime(2026, 10, 3), // gap on 4th and 5th
          DateTime(2026, 10, 2),
        ]),
        now: now,
      );

      expect(stats.streak, 0);
      expect(stats.totalDays, 3);
    });

    test('streak survives a week of consecutive mornings', () {
      final today = DateTime(2026, 10, 8);
      final stats = computeWakeUpStats(
        _entries([
          for (var i = 0; i < 7; i++) today.subtract(Duration(days: i)),
        ]),
        now: now,
      );

      expect(stats.streak, 7);
    });

    test('reports the most recent dismissal', () {
      final newest = DateTime(2026, 10, 8, 7, 4);
      final stats = computeWakeUpStats([
        {'at': newest.millisecondsSinceEpoch, 'method': 'qr'},
        {
          'at': DateTime(2026, 10, 7, 7).millisecondsSinceEpoch,
          'method': 'face',
        },
      ], now: now);

      expect(stats.lastAt, newest);
      expect(stats.lastMethod, 'qr');
    });

    test('ignores malformed entries instead of throwing', () {
      final stats = computeWakeUpStats([
        const {'at': 'not a number'},
        {'at': DateTime(2026, 10, 8, 7).millisecondsSinceEpoch},
      ], now: now);

      expect(stats.totalDays, 1);
      expect(stats.streak, 1);
    });
  });
}
