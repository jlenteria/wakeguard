import 'dart:math';

import 'alarm.dart';

/// One rung of the escalation ladder.
///
/// The same [EscalationPolicy] drives two completely different platform
/// mechanisms:
///
///  * **Android** walks [steps] inside a foreground service, rings at full
///    volume from the first step (volume-down is pinned back to maximum while
///    ringing), and additionally arms a watchdog [AlarmManager] entry per step
///    so that a killed service is recovered.
///  * **iOS** cannot run in the background at all, so each step becomes an
///    independently scheduled time-sensitive local notification.
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

  /// Hard ceiling on simultaneously pending notifications per app on iOS.
  /// The system keeps only the soonest [iosPendingNotificationCap] and silently
  /// discards the rest, which would quietly break future alarms.
  static const int iosPendingNotificationCap = 64;

  /// Reserved for unrelated notifications (repeats, reminders) so an alarm
  /// ladder never consumes the entire budget.
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

  /// Schedules [planned] alarms at their next occurrence, respecting the
  /// platform's pending-notification budget by walking alarms in
  /// soonest-first order.
  ///
  /// [usableSlots] is that budget in rungs, or null when the platform has no
  /// budget at all — Android's `AlarmManager` schedules without a cap, and
  /// reporting a cap there would produce a "will NOT ring" warning for an
  /// alarm that rings perfectly well.
  ///
  /// When a budget does apply, the return value is the subset that fits.
  /// Anything dropped is a real functional loss, so the caller is expected to
  /// surface it in the health dashboard rather than fail silently.
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

  /// Number of ladder entries for [alarmCount] alarms, used by the health
  /// dashboard to warn before iOS starts silently dropping notifications.
  int projectSlots(int alarmCount) => alarmCount * steps.length;
}

class PlannedAlarm {
  const PlannedAlarm({required this.alarm, required this.triggerAt});

  final Alarm alarm;
  final DateTime triggerAt;

  int get notificationIdSeed => alarm.id.hashCode & 0x7FFFFFFF;

  static int randomSeed() => Random().nextInt(1 << 30);
}
