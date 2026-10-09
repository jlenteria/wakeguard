import 'dart:math';

import 'alarm.dart';

/// One rung of the escalation ladder. Android walks [steps] in a foreground
/// service (with a watchdog per step); iOS schedules each step as its own
/// time-sensitive local notification since it cannot run in the background.
enum EscalationTier { gentle, firm, urgent, critical }

class EscalationStep {
  const EscalationStep({
    required this.offset,
    required this.tier,
    this.haptic = false,
  });

  /// Time after the alarm's nominal firing instant.
  final Duration offset;
  final EscalationTier tier;

  final bool haptic;

  String get soundAsset => 'alarm_${tier.name}';
}

class EscalationPolicy {
  const EscalationPolicy({
    required this.steps,
    required this.maxRingingDuration,
  });

  final List<EscalationStep> steps;

  /// After this the engine stops escalating and records the alarm as missed.
  final Duration maxRingingDuration;

  /// iOS caps pending notifications per app and silently keeps only the soonest;
  /// exceeding it would quietly break future alarms.
  static const int iosPendingNotificationCap = 64;

  /// Reserved for unrelated notifications so a ladder never uses the whole budget.
  static const int iosReservedSlots = 4;

  static int get iosUsableSlots => iosPendingNotificationCap - iosReservedSlots;

  static const EscalationPolicy standard = EscalationPolicy(
    maxRingingDuration: Duration(minutes: 15),
    steps: [
      EscalationStep(offset: Duration.zero, tier: EscalationTier.gentle),
      EscalationStep(
        offset: Duration(seconds: 45),
        tier: EscalationTier.firm,
        haptic: true,
      ),
      EscalationStep(
        offset: Duration(minutes: 2),
        tier: EscalationTier.urgent,
        haptic: true,
      ),
      EscalationStep(
        offset: Duration(minutes: 5),
        tier: EscalationTier.critical,
        haptic: true,
      ),
      EscalationStep(
        offset: Duration(minutes: 10),
        tier: EscalationTier.critical,
        haptic: true,
      ),
    ],
  );

  List<EscalationStep> get watchdogSteps =>
      steps.where((s) => s.offset > Duration.zero).toList(growable: false);

  EscalationTier tierAt(Duration elapsed) {
    var current = steps.first.tier;
    for (final step in steps) {
      if (elapsed >= step.offset) current = step.tier;
    }
    return current;
  }

  /// Schedules [planned] at their next occurrence, soonest-first, within
  /// [usableSlots] rungs (null = no cap, as on Android). Anything dropped will
  /// not ring, so the caller must surface it in the health dashboard.
  List<PlannedAlarm> plan(
    List<Alarm> alarms, {
    DateTime? from,
    int? usableSlots,
  }) {
    final now = from ?? DateTime.now();
    final ordered =
        alarms
            .where((a) => a.enabled)
            .map(
              (a) => PlannedAlarm(alarm: a, triggerAt: a.nextOccurrence(now)),
            )
            .toList()
          ..sort((a, b) => a.triggerAt.compareTo(b.triggerAt));

    final planned = <PlannedAlarm>[];
    var used = 0;
    for (final candidate in ordered) {
      if (usableSlots != null && used + steps.length > usableSlots) {
        break;
      }
      planned.add(candidate);
      used += steps.length;
    }
    return planned;
  }

  /// Ladder entries for one alarm, as absolute instants.
  List<DateTime> ladderFor(PlannedAlarm planned) => [
    for (final step in steps) planned.triggerAt.add(step.offset),
  ];

  /// Number of ladder entries, used to warn before iOS drops notifications.
  int projectSlots(int alarmCount) => alarmCount * steps.length;
}

class PlannedAlarm {
  const PlannedAlarm({required this.alarm, required this.triggerAt});

  final Alarm alarm;
  final DateTime triggerAt;

  int get notificationIdSeed => alarm.id.hashCode & 0x7FFFFFFF;

  static int randomSeed() => Random().nextInt(1 << 30);
}
