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
  List<HealthCheck> get warnings => checks
      .where((check) => check.severity == HealthSeverity.warning)
      .toList();
  bool get readinessKnown =>
      controller.capabilities != null && controller.fatalError == null;
  bool get hasEnabledAlarms => alarms.any((alarm) => alarm.enabled);
  final Set<String> _busy = {};
  bool isBusy(String id) => _busy.contains(id);
  bool _refreshing = false;
  bool get refreshing => _refreshing;

  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    safeNotify();
    try {
      await controller.reload();
      await controller.refreshHealth();
      if (controller.fatalError != null) {
        throw StateError(controller.fatalError!);
      }
    } finally {
      _refreshing = false;
      safeNotify();
    }
  }

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

  Alarm? get nextAlarm {
    final at = nextTrigger;
    if (at == null) return null;
    for (final alarm in alarms) {
      if (alarm.enabled && fireTime(alarm.id) == at) return alarm;
    }
    return null;
  }

  bool cameraPermissionMissingFor(Alarm alarm) =>
      controller.cameraPermissionMissingFor(alarm);

  void clearError() => controller.clearError();

  /// Returns true when the camera is the reason the alarm could not be enabled.
  Future<bool> toggle(Alarm alarm, bool enabled) async {
    if (isBusy(alarm.id)) return false;
    return _mutate(alarm, () async {
      await controller.setEnabled(alarm, enabled);
      final cameraMissing =
          enabled && controller.cameraPermissionMissingFor(alarm);
      if (!cameraMissing && controller.lastError != null) {
        throw StateError(controller.lastError!);
      }
      return cameraMissing;
    });
  }

  Future<T> _mutate<T>(Alarm alarm, Future<T> Function() operation) async {
    _busy.add(alarm.id);
    safeNotify();
    try {
      return await operation();
    } finally {
      _busy.remove(alarm.id);
      safeNotify();
    }
  }

  Future<bool> delete(Alarm alarm) async {
    if (isBusy(alarm.id)) return false;
    return _mutate(alarm, () => controller.delete(alarm));
  }

  Future<void> restore(Alarm alarm) => _mutate(alarm, () async {
    await controller.upsert(alarm);
    if (controller.lastError != null) throw StateError(controller.lastError!);
  });
  Future<void> duplicate(Alarm alarm) async {
    if (isBusy(alarm.id)) return;
    await _mutate(alarm, () => controller.duplicate(alarm));
  }

  bool isSkipped(Alarm alarm) =>
      alarm.skipUntilMillis > DateTime.now().millisecondsSinceEpoch;

  Future<void> toggleSkip(Alarm alarm) async {
    if (isBusy(alarm.id)) return;
    await _mutate(
      alarm,
      () => isSkipped(alarm)
          ? controller.restoreNext(alarm)
          : controller.skipNext(alarm),
    );
  }

  @override
  void dispose() {
    controller.removeListener(safeNotify);
    super.dispose();
  }
}
