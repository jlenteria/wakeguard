import 'package:flutter_test/flutter_test.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/models/reconcile.dart';

Alarm _alarm(String id, {int hour = 7, int minute = 0, bool enabled = true}) =>
    Alarm(id: id, hour: hour, minute: minute, label: id, enabled: enabled);

void main() {
  group('reconcileAlarms', () {
    test('leaves an in-sync set untouched', () {
      final alarms = [_alarm('a'), _alarm('b', hour: 8)];
      final result = reconcileAlarms(mirror: alarms, native: alarms);

      expect(result.alarms, hasLength(2));
      expect(result.needsSave, isFalse);
      expect(result.toSchedule, isEmpty);
    });

    test('platform wins when it retired a one-shot that just fired', () {
      final mirror = _alarm('a');
      final result = reconcileAlarms(
        mirror: [mirror],
        native: [_alarm('a', enabled: false)],
      );

      expect(result.alarms.single.enabled, isFalse);
      expect(result.needsSave, isTrue);
      expect(result.toSchedule, isEmpty);
    });

    test('platform wins when it reports an alarm the mirror has off', () {
      final result = reconcileAlarms(
        mirror: [_alarm('a', enabled: false)],
        native: [_alarm('a', enabled: true)],
      );

      expect(result.alarms.single.enabled, isTrue);
      // Already scheduled natively: re-arming could cancel a pending check-in.
      expect(result.toSchedule, isEmpty);
    });

    test('re-arms an alarm the platform has no record of', () {
      final result = reconcileAlarms(mirror: [_alarm('a')], native: const []);

      expect(result.alarms, hasLength(1));
      expect(result.needsSave, isFalse);
      expect(result.toSchedule.map((a) => a.id), ['a']);
    });

    test('a disabled mirror alarm missing natively is not re-armed', () {
      final result = reconcileAlarms(
        mirror: [_alarm('a', enabled: false)],
        native: const [],
      );

      expect(result.alarms.single.enabled, isFalse);
      expect(result.toSchedule, isEmpty);
    });

    test('keeps an alarm only the platform knows about', () {
      final result = reconcileAlarms(
        mirror: const [],
        native: [_alarm('native-only', hour: 6, minute: 30)],
      );

      expect(result.alarms.single.id, 'native-only');
      expect(result.needsSave, isTrue);
      // Native-only is already armed, so it is kept in the mirror, not re-scheduled.
      expect(result.toSchedule, isEmpty);
    });

    test('mirror fields survive a platform disagreement on enabled', () {
      final result = reconcileAlarms(
        mirror: [_alarm('a', hour: 9, minute: 5)],
        native: [
          const Alarm(
            id: 'a',
            hour: 7,
            minute: 0,
            label: 'stale platform copy',
            enabled: false,
          ),
        ],
      );

      final merged = result.alarms.single;
      expect(merged.enabled, isFalse);
      // The editor's copy of time and label is what the user last saved.
      expect(merged.hour, 9);
      expect(merged.minute, 5);
      expect(merged.label, 'a');
    });

    test('returns alarms ordered by time of day', () {
      final result = reconcileAlarms(
        mirror: [_alarm('late', hour: 22), _alarm('early', hour: 6)],
        native: [_alarm('mid', hour: 7), _alarm('late', hour: 22)],
      );

      expect(result.alarms.map((a) => a.id), ['early', 'mid', 'late']);
    });
  });
}
