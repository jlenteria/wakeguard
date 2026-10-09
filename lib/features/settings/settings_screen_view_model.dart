import '../alarms/alarm_controller.dart';
import '../../models/app_settings.dart';
import '../../models/wake_up_stats.dart';
import 'settings_controller.dart';
import '../challenges/wake_up_qr.dart';
import '../../shared/view_model.dart';

/// App-wide preferences plus the wake-up record shown beside them.
class SettingsScreenViewModel extends ViewModel {
  SettingsScreenViewModel(this.controller, this.settings) {
    controller.addListener(safeNotify);
    settings.addListener(safeNotify);
  }

  final AlarmController controller;
  final SettingsController settings;

  AppSettings get value => settings.settings;
  WakeUpStats get stats => controller.wakeUpStats;

  Future<void> update(AppSettings next) => settings.update((_) => next);

  /// The shared wake-up QR, adopting the first existing code before generating one.
  Future<String> wakeUpQrValue() {
    final codes = controller.alarms
        .map((a) => a.qrValue.trim())
        .where((code) => code.isNotEmpty);
    return WakeUpQrRepository().getOrCreate(
        preferredValue: codes.isEmpty ? null : codes.first);
  }

  static String snoozeLabel(int minutes) =>
      minutes == 0 ? 'No snooze' : '$minutes min';

  static String methodLabel(String? method) => switch (method) {
    null => 'Dismissal',
    'face' => 'Face challenge',
    'tap' => 'Tap to stop',
    'checkin' => 'Check-in confirmed',
    'qr' => 'QR code',
    'pattern' => 'Pattern',
    'hold' => 'Hold to stop',
    'settings' => 'From settings',
    _ => 'Dismissal',
  };

  static String ago(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) {
      return '${delta.inHours}h ${delta.inMinutes % 60}m ago';
    }
    return '${delta.inDays}d ago';
  }

  @override
  void dispose() {
    controller.removeListener(safeNotify);
    settings.removeListener(safeNotify);
    super.dispose();
  }
}
