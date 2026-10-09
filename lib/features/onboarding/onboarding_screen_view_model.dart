import '../alarms/alarm_controller.dart';
import '../../shared/view_model.dart';

/// First-run state: the three settings that decide whether an alarm rings.
class OnboardingScreenViewModel extends ViewModel {
  OnboardingScreenViewModel(this.controller, {required this.onDone}) {
    controller.addListener(safeNotify);
  }

  final AlarmController controller;
  final Future<void> Function() onDone;

  bool _requestingNotifications = false;

  bool get requestingNotifications => _requestingNotifications;
  bool get hasChecks => controller.checks.isNotEmpty;
  bool get ready => controller.unresolvedChecks.isEmpty;
  String? get lastError => controller.lastError;
  String get pendingSummary =>
      'Still needed: ${controller.unresolvedChecks.map((c) => c.label).join(', ')}';

  Future<String?> requestNotifications() async {
    _requestingNotifications = true;
    safeNotify();
    try {
      await controller.engine.requestPermissions();
      await controller.refreshHealth();
      return null;
    } catch (error) {
      return '$error';
    } finally {
      _requestingNotifications = false;
      safeNotify();
    }
  }

  Future<void> runPreflight() => controller.runPreflight();
  Future<String?> allowExactAlarms() => controller.openFix('exact_alarm');
  Future<void> finish() => onDone();

  @override
  void dispose() {
    controller.removeListener(safeNotify);
    super.dispose();
  }
}
