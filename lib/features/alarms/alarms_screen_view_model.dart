import '../../models/alarm.dart';
import 'alarm_controller.dart';
import '../../models/health.dart';
import '../../shared/view_model.dart';

/// What the alarm list shows and the actions each row offers.
class AlarmsScreenViewModel extends ViewModel {
  AlarmsScreenViewModel(this.controller) {
    controller.addListener(safeNotify);
  }

  final AlarmController controller;

  bool get loading => controller.loading;
  String? get lastError => controller.lastError;
  List<Alarm> get alarms => controller.alarms;
  List<Alarm> get dropped => controller.droppedAlarms;
  bool get isEmpty => controller.alarms.isEmpty;
  List<HealthCheck> get checks => controller.checks;
  List<HealthCheck> get unresolvedChecks => controller.unresolvedChecks;

  /// Soonest armed trigger, or null when nothing is scheduled.
  DateTime? get nextTrigger {
    if (controller.alarms.isEmpty) return null;
    DateTime? soonest;
    for (final planned in controller.planned) {
      final at = controller.nextFireTime(planned.alarm.id) ?? planned.triggerAt;
      if (soonest == null || at.isBefore(soonest)) soonest = at;
    }
    return soonest;
  }

  DateTime? fireTime(String alarmId) => controller.nextFireTime(alarmId);

  bool cameraPermissionMissingFor(Alarm alarm) =>
      controller.cameraPermissionMissingFor(alarm);

  void clearError() => controller.clearError();

  /// Returns true when the camera is the reason the alarm could not be enabled.
  Future<bool> toggle(Alarm alarm, bool enabled) async {
    await controller.setEnabled(alarm, enabled);
    return enabled && controller.cameraPermissionMissingFor(alarm);
  }

  Future<bool> delete(Alarm alarm) => controller.delete(alarm);
  Future<void> restore(Alarm alarm) => controller.upsert(alarm);
  Future<void> duplicate(Alarm alarm) => controller.duplicate(alarm);

  bool isSkipped(Alarm alarm) =>
      alarm.skipUntilMillis > DateTime.now().millisecondsSinceEpoch;

  Future<void> toggleSkip(Alarm alarm) =>
      isSkipped(alarm) ? controller.restoreNext(alarm) : controller.skipNext(alarm);

  @override
  void dispose() {
    controller.removeListener(safeNotify);
    super.dispose();
  }
}
