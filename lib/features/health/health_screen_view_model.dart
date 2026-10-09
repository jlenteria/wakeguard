import '../alarms/alarm_controller.dart';
import '../../models/health.dart';
import '../../shared/view_model.dart';

/// Readiness checks and the fixes that clear them.
class HealthScreenViewModel extends ViewModel {
  HealthScreenViewModel(this.controller) {
    controller.addListener(safeNotify);
  }

  final AlarmController controller;

  EngineCapabilities? get capabilities => controller.capabilities;
  List<HealthCheck> get checks => controller.checks;
  List<HealthCheck> get blocking =>
      checks.where((c) => c.severity == HealthSeverity.blocking).toList();

  Future<String?> openFix(String action) => controller.openFix(action);
  Future<void> runPreflight() => controller.runPreflight();

  @override
  void dispose() {
    controller.removeListener(safeNotify);
    super.dispose();
  }
}
