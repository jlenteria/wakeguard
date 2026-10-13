import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/models/escalation.dart';

/// Pins the shared weekday encoding (Dart 1=Mon..7=Sun; Android/iOS
/// 1=Sun..7=Sat) so the native translation cannot be dropped unnoticed.
void main() {
  Alarm alarm({
    String id = 'a',
    int hour = 7,
    int minute = 30,
    Set<int> weekdays = const <int>{},
    bool enabled = true,
  }) => Alarm(
    id: id,
    hour: hour,
    minute: minute,
    label: 'Wake up',
    enabled: enabled,
    weekdays: weekdays,
  );

  group('weekday encoding', () {
    test('1=Monday and 7=Sunday, matching DateTime.weekday', () {
      // 2026-10-05 is a Monday and 2026-10-11 is a Sunday.
      final monday = DateTime(2026, 10, 5);
      final sunday = DateTime(2026, 10, 11);
      expect(monday.weekday, 1);
      expect(sunday.weekday, 7);

      expect(alarm(weekdays: {1}).isScheduledFor(monday), isTrue);
      expect(alarm(weekdays: {1}).isScheduledFor(sunday), isFalse);
      expect(alarm(weekdays: {7}).isScheduledFor(sunday), isTrue);
    });

    test('a Monday-only alarm skips to next Monday', () {
      final wednesday = DateTime(2026, 10, 7, 9);
      final next = alarm(
        weekdays: {1},
        hour: 7,
        minute: 30,
      ).nextOccurrence(wednesday);

      // Wednesday 2026-10-07 -> Monday 2026-10-12.
      expect(next.weekday, DateTime.monday);
      expect(next, DateTime(2026, 10, 12, 7, 30));
      expect(next.hour, 7);
      expect(next.minute, 30);
      expect(next.isAfter(wednesday), isTrue);
    });

    test('a Sunday-only alarm wraps across the week boundary', () {
      final monday = DateTime(2026, 10, 5, 9);
      final next = alarm(
        weekdays: {7},
        hour: 7,
        minute: 30,
      ).nextOccurrence(monday);

      // Monday 2026-10-05 -> Sunday 2026-10-11, across the week boundary.
      expect(next.weekday, DateTime.sunday);
      expect(next, DateTime(2026, 10, 11, 7, 30));
    });

    test('multi-day selection picks the soonest matching day', () {
      // From a Thursday: Monday is 4 days out, Saturday is 2 days out.
      final thursday = DateTime(2026, 10, 8, 23, 59);
      final next = alarm(
        weekdays: {1, 6},
        hour: 7,
        minute: 30,
      ).nextOccurrence(thursday);

      expect(next.weekday, 6);
    });

    test('empty weekday set means every day', () {
      // Tuesday 09:00, so today's 07:30 has already passed: tomorrow.
      final tuesday = DateTime(2026, 10, 6, 9);
      final next = alarm().nextOccurrence(tuesday);

      expect(next, DateTime(2026, 10, 7, 7, 30));
      expect(next.hour, 7);
    });
  });

  group('next occurrence', () {
    test('always returns something strictly in the future', () {
      final exact = DateTime(2026, 10, 7, 7, 30);
      final next = alarm(hour: 7, minute: 30).nextOccurrence(exact);

      expect(next.isAfter(exact), isTrue);
      expect(next.day, 8);
    });

    test('keeps wall-clock time rather than adding a fixed 24h', () {
      // Guards the DST bug: adding Duration(days: 1) shifts the wall-clock hour.
      final beforeDst = DateTime(2026, 3, 7, 7, 30);
      final next = alarm(hour: 7, minute: 30).nextOccurrence(beforeDst);

      expect(next.hour, 7);
      expect(next.minute, 30);
    });

    test('invalid hour or minute cannot be produced', () {
      final next = alarm(
        hour: 23,
        minute: 59,
      ).nextOccurrence(DateTime(2026, 1, 1));
      expect(next.hour, lessThanOrEqualTo(23));
      expect(next.minute, lessThanOrEqualTo(59));
    });
  });

  group('escalation policy', () {
    const policy = EscalationPolicy.standard;

    test('rungs are ordered and start at zero', () {
      expect(policy.steps.first.offset, Duration.zero);
      for (var i = 1; i < policy.steps.length; i++) {
        expect(
          policy.steps[i].offset,
          greaterThan(policy.steps[i - 1].offset),
          reason: 'offsets must increase',
        );
      }
    });

    test('tierAt tracks elapsed time', () {
      expect(policy.tierAt(Duration.zero), EscalationTier.gentle);
      expect(policy.tierAt(const Duration(seconds: 45)), EscalationTier.firm);
      expect(
        policy.tierAt(const Duration(minutes: 5)),
        EscalationTier.critical,
      );
    });

    test('watchdog skips the rung that the service itself fires', () {
      // The service fires offset 0 itself; a watchdog at 0s would race and double-fire.
      expect(policy.watchdogSteps, isNotEmpty);
      expect(
        policy.watchdogSteps.every((s) => s.offset > Duration.zero),
        isTrue,
      );
    });

    test('every rung stays inside maxRingingDuration', () {
      final last = policy.steps.last.offset;
      expect(last, lessThanOrEqualTo(policy.maxRingingDuration));
    });
  });

  group('iOS pending-notification budget', () {
    test('reserved slots keep the cap from being fully consumed', () {
      expect(EscalationPolicy.iosUsableSlots, 60);
    });

    test('a single ladder fits comfortably', () {
      const policy = EscalationPolicy.standard;
      expect(
        policy.steps.length,
        lessThanOrEqualTo(EscalationPolicy.iosUsableSlots),
      );
    });

    test('plan keeps soonest alarms and drops the rest', () {
      const policy = EscalationPolicy.standard;
      // More alarms than the budget allows: 60 / 5 rungs = 12 alarms.
      final many = [
        for (var i = 0; i < 20; i++)
          alarm(id: 'a$i', hour: i % 24, minute: (i * 7) % 60),
      ];

      final planned = policy.plan(
        many,
        from: DateTime(2026, 10, 7, 12),
        usableSlots: EscalationPolicy.iosUsableSlots,
      );
      final dropped = many.length - planned.length;

      expect(planned.length, 12);
      expect(dropped, 8);
      expect(
        planned.length * policy.steps.length,
        lessThanOrEqualTo(EscalationPolicy.iosUsableSlots),
      );
      // Kept alarms must be the soonest, or the budget sacrifices the one most needed.
      final allTimes = [
        for (final a in many) a.nextOccurrence(DateTime(2026, 10, 7, 12)),
      ]..sort();
      expect(planned.map((p) => p.triggerAt), allTimes.take(12));
    });

    test('no budget means nothing is dropped', () {
      // Android reports pendingSlotCap: null; using the iOS cap gave false "will NOT ring".
      const policy = EscalationPolicy.standard;
      final many = [
        for (var i = 0; i < 20; i++)
          alarm(id: 'a$i', hour: i % 24, minute: (i * 7) % 60),
      ];

      final planned = policy.plan(many, from: DateTime(2026, 10, 7, 12));

      expect(planned.length, many.length);
    });

    test('disabled alarms are never planned', () {
      const policy = EscalationPolicy.standard;
      final planned = policy.plan([
        alarm(id: 'off', enabled: false),
        alarm(id: 'on', hour: 6),
      ], from: DateTime(2026, 10, 7, 12));

      expect(planned.map((p) => p.alarm.id), ['on']);
    });

    test('fewer alarms than the budget are all planned', () {
      const policy = EscalationPolicy.standard;
      final planned = policy.plan([
        alarm(id: 'a'),
        alarm(id: 'b', hour: 8),
      ], from: DateTime(2026, 10, 7, 12));

      expect(planned.length, 2);
    });
  });

  group('serialisation', () {
    test('weekdays survive a JSON round trip', () {
      final original = alarm(id: 'x', weekdays: {1, 3, 5});
      final restored = Alarm.fromJson(original.toJson());

      expect(restored.weekdays, {1, 3, 5});
      expect(restored.id, original.id);
      expect(restored.difficulty, original.difficulty);
    });

    test('ids are unique', () {
      final ids = {for (var i = 0; i < 500; i++) Alarm.generateId()};
      expect(ids.length, 500);
    });
  });

  group('escapes', () {
    test('object choices contain only Sink and Cup', () {
      expect(WakeObject.values.map((target) => target.name), ['sink', 'cup']);
    });

    test(
      'removed Plant alarms require new setup without reusing verification',
      () {
        final json =
            Alarm(id: 'plant', hour: 7, minute: 0, label: 'Plant').toJson()
              ..['escapes'] = ['object']
              ..['objectTarget'] = 'plant'
              ..['objectVerified'] = true;
        final migrated = Alarm.fromJson(json);
        expect(migrated.enabled, isFalse);
        expect(migrated.needsSetup, isTrue);
        expect(migrated.objectTarget, WakeObject.sink);
        expect(migrated.objectVerified, isFalse);
        expect(migrated.escapes, {EscapeKind.object});
      },
    );

    test(
      'supported Cup alarms keep their selected target and verification',
      () {
        final original = Alarm(
          id: 'cup',
          hour: 7,
          minute: 0,
          label: 'Cup',
          escapes: {EscapeKind.object},
          objectTarget: WakeObject.cup,
          objectVerified: true,
        );
        final restored = Alarm.fromJson(original.toJson());
        expect(restored.enabled, isTrue);
        expect(restored.needsSetup, isFalse);
        expect(restored.objectTarget, WakeObject.cup);
        expect(restored.objectVerified, isTrue);
      },
    );

    test('a new alarm offers Face without opting into Tap', () {
      final created = Alarm(id: 'a', hour: 7, minute: 0, label: 'x');
      expect(created.escapes, {EscapeKind.face});
    });

    test('a chosen subset survives a JSON round trip', () {
      final original = Alarm(
        id: 'x',
        hour: 7,
        minute: 0,
        label: 'x',
        escapes: {EscapeKind.tap},
      );
      expect(Alarm.fromJson(original.toJson()).escapes, {EscapeKind.tap});
    });

    test('a record from before escapes existed defaults to Face', () {
      final json = Alarm(id: 'a', hour: 7, minute: 0, label: 'x').toJson()
        ..remove('escapes');
      expect(Alarm.fromJson(json).escapes, Alarm.defaultEscapes);
    });

    test('a field from a newer build drops names this one does not know', () {
      final json = Alarm(id: 'a', hour: 7, minute: 0, label: 'x').toJson()
        ..['escapes'] = ['face', 'telepathy'];
      expect(Alarm.fromJson(json).escapes, {EscapeKind.face});
    });

    test(
      'legacy Pattern-only alarms require object setup and stay disabled',
      () {
        final json = Alarm(id: 'a', hour: 7, minute: 0, label: 'x').toJson()
          ..['escapes'] = ['pattern'];
        final migrated = Alarm.fromJson(json);
        expect(migrated.escapes, {EscapeKind.object});
        expect(migrated.needsSetup, isTrue);
        expect(migrated.enabled, isFalse);
      },
    );

    test('usesFace follows the set, so the camera check can see it', () {
      final withoutFace = Alarm(
        id: 'a',
        hour: 7,
        minute: 0,
        label: 'x',
        escapes: {EscapeKind.tap},
      );
      expect(withoutFace.usesFace, isFalse);
      expect(Alarm(id: 'b', hour: 7, minute: 0, label: 'x').usesFace, isTrue);
    });
  });

  group('sound pack', () {
    test('Stay Awake has its own short notification chime', () {
      final bytes = File(
        'android/app/src/main/res/raw/checkin_reminder.wav',
      ).readAsBytesSync();
      expect(String.fromCharCodes(bytes.take(4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      final header = ByteData.sublistView(bytes);
      expect(header.getUint16(20, Endian.little), 1); // Uncompressed PCM.
      final channels = header.getUint16(22, Endian.little);
      final rate = header.getUint32(24, Endian.little);
      final bits = header.getUint16(34, Endian.little);
      final duration =
          header.getUint32(40, Endian.little) / (rate * channels * bits / 8);
      expect(duration, inInclusiveRange(0.5, 2.0));
      expect(bytes.skip(44).any((sample) => sample != 0), isTrue);
    });

    test(
      'defaults to pulse so an alarm saved without one is still audible',
      () {
        expect(
          Alarm(id: 'a', hour: 7, minute: 0, label: 'x').soundPack,
          AlarmSoundPack.pulse,
        );
      },
    );

    test('survives a JSON round trip', () {
      final alarm = Alarm(
        id: 'a',
        hour: 6,
        minute: 30,
        label: 'x',
        soundPack: AlarmSoundPack.gong,
      );
      expect(Alarm.fromJson(alarm.toJson()).soundPack, AlarmSoundPack.gong);
    });

    test('falls back rather than throwing on a value from a newer build', () {
      final json = Alarm(id: 'a', hour: 7, minute: 0, label: 'x').toJson()
        ..['soundPack'] = 'bagpipes';
      expect(Alarm.fromJson(json).soundPack, AlarmSoundPack.pulse);
    });

    test('every pack has a distinct label and description', () {
      final labels = AlarmSoundPack.values.map((p) => p.label).toSet();
      final descriptions = AlarmSoundPack.values
          .map((p) => p.description)
          .toSet();
      expect(labels.length, AlarmSoundPack.values.length);
      expect(descriptions.length, AlarmSoundPack.values.length);
    });

    test('names match the assets generated for both platforms', () {
      // Dart, Kotlin and Swift name these assets independently, so naming can drift here.
      const packs = ['pulse', 'siren', 'radar', 'gong'];
      expect(AlarmSoundPack.values.map((p) => p.name), packs);

      for (final pack in AlarmSoundPack.values) {
        expect(pack.name, matches(RegExp(r'^[a-z]+$')));
        // Android ships two tiers: the service loops, so gentle then critical.
        for (final tier in const ['gentle', 'critical']) {
          expect(
            File(
              'android/app/src/main/res/raw/tone_${pack.name}_$tier.wav',
            ).existsSync(),
            isTrue,
            reason: 'missing Android asset for ${pack.name}/$tier',
          );
        }
        // iOS cannot loop in the background, so it needs every tier.
        for (final tier in const ['gentle', 'firm', 'urgent', 'critical']) {
          expect(
            File('ios/Runner/tone_${pack.name}_$tier.caf').existsSync(),
            isTrue,
            reason: 'missing iOS asset for ${pack.name}/$tier',
          );
        }
      }
    });
  });
}
