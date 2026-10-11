import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../models/alarm.dart';
import '../alarms/alarm_controller.dart';
import '../settings/settings_controller.dart';
import '../../platform/alarm_engine.dart';
import '../../shared/view_model.dart';

/// Owns shell state: the selected tab, the minute tick, app lifecycle and the
/// draft kept aside when a Face/QR alarm cannot be saved without camera access.
class ShellScreenViewModel extends ViewModel with WidgetsBindingObserver {
  ShellScreenViewModel({
    required this.engine,
    required this.controller,
    required this.settings,
  }) {
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(safeNotify);
    settings.addListener(safeNotify);
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_foreground && _tab == 0) {
        _tick++;
        safeNotify();
      }
    });
  }

  final AlarmEngine engine;
  final AlarmController controller;
  final SettingsController settings;

  Timer? _clock;
  int _tab = 0;
  bool _foreground = true;
  bool _cameFromAlarm = false;
  Alarm? _pendingCameraDraft;
  bool _editorOpen = false;

  /// Bumped each minute while the alarms tab is visible, so relative times refresh.
  int _tick = 0;

  int get tab => _tab;
  int get tick => _tick;
  Alarm? get pendingCameraDraft => _pendingCameraDraft;
  bool get editorOpen => _editorOpen;

  bool beginEditor() {
    if (_editorOpen) return false;
    _editorOpen = true;
    safeNotify();
    return true;
  }

  void endEditor() {
    _editorOpen = false;
    safeNotify();
  }

  /// True when Health was opened from the alarm flow, so it can offer a way back.
  bool get cameFromAlarm => _cameFromAlarm;

  void selectTab(int index) {
    if (index == _tab) return;
    // Leaving the tab would otherwise keep the audibility sample ringing.
    unawaited(controller.stopAudibilitySample());
    // A plain tab change did not come from the alarm flow.
    _cameFromAlarm = false;
    _tab = index;
    safeNotify();
  }

  /// Opens Health from the alarm flow; remembered so "Return to alarm" shows.
  void openHealth() {
    selectTab(1);
    _cameFromAlarm = true;
    safeNotify();
  }

  void setPendingCameraDraft(Alarm? alarm) {
    _pendingCameraDraft = alarm;
    safeNotify();
  }

  /// On foreground: reconcile alarms fired while closed and refresh health.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      unawaited(controller.refreshHealth());
      unawaited(controller.reload());
    } else {
      unawaited(controller.stopAudibilitySample());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(safeNotify);
    settings.removeListener(safeNotify);
    _clock?.cancel();
    super.dispose();
  }
}
