import 'alarm.dart';

/// Outcome of comparing the Dart mirror with the platform's own record.
class ReconciledAlarms {
  const ReconciledAlarms({
    required this.alarms,
    required this.needsSave,
    required this.toSchedule,
  });

  /// The merged alarm set, ordered by time of day.
  final List<Alarm> alarms;

  /// True when [alarms] differs from the mirror and should be written back.
  final bool needsSave;

  /// Enabled alarms the platform has no record of, which must be scheduled.
  final List<Alarm> toSchedule;
}

/// Merges the Dart mirror with the native record: the platform decides
/// [Alarm.enabled] and existence, everything else stays with the mirror.
/// Mirrored alarms missing natively are re-scheduled, never silently dropped.
ReconciledAlarms reconcileAlarms({
  required List<Alarm> mirror,
  required List<Alarm> native,
}) {
  final nativeById = {for (final alarm in native) alarm.id: alarm};
  final merged = <Alarm>[];
  final toSchedule = <Alarm>[];
  var changed = false;

  for (final alarm in mirror) {
    final platform = nativeById.remove(alarm.id);
    if (platform == null) {
      merged.add(alarm);
      if (alarm.enabled) toSchedule.add(alarm);
      continue;
    }
    if (platform.enabled == alarm.enabled) {
      merged.add(alarm);
      continue;
    }
    changed = true;
    final reconciled = alarm.copyWith(enabled: platform.enabled);
    merged.add(reconciled);
    if (reconciled.enabled) toSchedule.add(reconciled);
  }

  // Native-only alarms are kept: dropping them would cancel a working alarm.
  if (nativeById.isNotEmpty) {
    changed = true;
    merged.addAll(nativeById.values);
  }

  merged.sort((a, b) => a.minuteOfDay - b.minuteOfDay);
  return ReconciledAlarms(alarms: merged, needsSave: changed, toSchedule: toSchedule);
}
