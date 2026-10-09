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

/// Merges the Dart mirror with what the platform actually holds.
///
/// The platform store is authoritative for [Alarm.enabled] and for existence,
/// because it is what the OS will act on. Everything else (time, label, sound)
/// stays with the mirror, since that is what the editor writes and what a
/// failed schedule call may not have delivered yet.
///
/// Two real bugs are fixed here:
///
///  * A one-shot that fired while the app was closed disables itself in the
///    platform store only. The mirror kept claiming it was on, so the switch
///    lied and the next edit re-armed a retired alarm.
///  * An alarm present in the mirror but missing natively would never ring
///    again — the mirror alone schedules nothing. Those are re-scheduled rather
///    than hidden, so a cleared native store cannot silently delete alarms.
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

  // Anything only the platform knows about was scheduled from somewhere this
  // mirror does not remember (a restore, or an older build). Keeping it is the
  // conservative choice: dropping it would silently cancel a working alarm.
  if (nativeById.isNotEmpty) {
    changed = true;
    merged.addAll(nativeById.values);
  }

  merged.sort((a, b) => a.minuteOfDay - b.minuteOfDay);
  return ReconciledAlarms(alarms: merged, needsSave: changed, toSchedule: toSchedule);
}
