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
  List<HealthCheck> get warnings =>
      checks.where((c) => c.severity == HealthSeverity.warning).toList();
  List<HealthCheck> get passed =>
      checks.where((c) => c.severity == HealthSeverity.ok).toList();
  bool get playing => controller.audibilityTestPlaying;
  bool _refreshing = false;
  String? _fixingAction;
  bool get refreshing => _refreshing;
  String? get fixingAction => _fixingAction;

  Future<String?> refresh() async {
    if (_refreshing) return null;
    _refreshing = true;
    safeNotify();
    try {
      await controller.refreshHealth();
      return controller.fatalError;
    } catch (error) {
      return '$error';
    } finally {
      _refreshing = false;
      safeNotify();
    }
  }

  Future<String?> openFix(String action) async {
    _fixingAction = action;
    safeNotify();
    try {
      final failure = await controller.openFix(action);
      return failure ?? controller.fatalError;
    } catch (error) {
      return '$error';
    } finally {
      _fixingAction = null;
      safeNotify();
    }
  }

  Future<String?> runPreflight() async {
    await controller.runPreflight();
    return controller.lastError ?? controller.fatalError;
  }

  Future<void> stopTest() => controller.stopAudibilitySample();

  @override
  void dispose() {
    controller.removeListener(safeNotify);
    super.dispose();
  }
}
