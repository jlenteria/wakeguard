import 'dart:async';

import 'package:package_info_plus/package_info_plus.dart';

import '../alarms/alarm_controller.dart';
import '../../models/app_settings.dart';
import 'settings_controller.dart';
import '../challenges/wake_up_qr.dart';
import '../../shared/view_model.dart';

/// App-wide preferences, package information and the shared wake-up code.
class SettingsScreenViewModel extends ViewModel {
  SettingsScreenViewModel(this.controller, this.settings) {
    controller.addListener(safeNotify);
    settings.addListener(safeNotify);
    unawaited(_loadVersion());
  }

  final AlarmController controller;
  final SettingsController settings;

  AppSettings get value => settings.settings;
  String _version = 'Loading…';
  String get version => _version;
  bool _openingQr = false;
  bool get openingQr => _openingQr;
  bool _loadingQr = false;
  bool get loadingQr => _loadingQr;

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _version =
          '${info.version}${info.buildNumber.isEmpty ? '' : ' (${info.buildNumber})'}';
    } catch (_) {
      _version = 'Unavailable';
    }
    safeNotify();
  }

  bool beginQrOpen() {
    if (_openingQr) return false;
    _openingQr = true;
    _loadingQr = true;
    safeNotify();
    return true;
  }

  void endQrOpen() {
    _openingQr = false;
    _loadingQr = false;
    safeNotify();
  }

  void finishQrLoad() {
    _loadingQr = false;
    safeNotify();
  }

  Future<void> update(AppSettings next) => settings.update((_) => next);

  /// The shared wake-up QR, adopting the first existing code before generating one.
  Future<String> wakeUpQrValue() {
    final codes = controller.alarms
        .map((a) => a.qrValue.trim())
        .where((code) => code.isNotEmpty);
    return WakeUpQrRepository().getOrCreate(
      preferredValue: codes.isEmpty ? null : codes.first,
    );
  }

  static String snoozeLabel(int minutes) =>
      minutes == 0 ? 'No snooze' : '$minutes min';

  @override
  void dispose() {
    controller.removeListener(safeNotify);
    settings.removeListener(safeNotify);
    super.dispose();
  }
}
