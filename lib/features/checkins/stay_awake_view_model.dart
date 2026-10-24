import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../models/check_in.dart';
import '../../platform/alarm_engine.dart';
import '../../shared/view_model.dart';
import '../alarms/alarm_controller.dart';

class StayAwakeViewModel extends ViewModel with WidgetsBindingObserver {
  StayAwakeViewModel(AlarmEngine engine, this.controller)
    : _engine = engine is CheckInEngine ? engine as CheckInEngine : null {
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (_foreground) _start();
  }

  final CheckInEngine? _engine;
  final AlarmController controller;
  List<PendingCheckIn> _pending = const [];
  DateTime _now = DateTime.now();
  Timer? _timer;
  bool _foreground = true;
  bool _refreshing = false;
  bool _confirming = false;
  int _refreshRevision = 0;
  String? error;

  PendingCheckIn? get current {
    for (final checkIn in _pending) {
      if (checkIn.isAnswerable(_now)) return checkIn;
    }
    return null;
  }

  int get remainingSeconds => current?.remainingSeconds(_now) ?? 0;
  bool get confirming => _confirming;

  void _start() {
    if (_engine == null || _timer != null) return;
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final wasVisible = current != null;
      _now = DateTime.now();
      if (wasVisible || current != null) safeNotify();
      // Windows are only listed once their native prompt has been shown, so poll
      // every tick to show the card with the notification and reflect confirmations.
      unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    final engine = _engine;
    if (engine == null ||
        _refreshing ||
        _confirming ||
        !_foreground ||
        disposed) {
      return;
    }
    _refreshing = true;
    final revision = _refreshRevision;
    try {
      final pending = await engine.pendingCheckIns();
      if (disposed || !_foreground || revision != _refreshRevision) return;
      final previous = current?.sessionId;
      _pending = pending;
      _now = DateTime.now();
      if (previous != current?.sessionId) error = null;
      safeNotify();
    } catch (error) {
      // A transient channel error must not hide an already-known live window.
      debugPrint('WakeGuard check-in refresh failed: $error');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> confirm() async {
    final checkIn = current;
    final engine = _engine;
    if (_confirming || checkIn == null || engine == null) return;
    _confirming = true;
    _refreshRevision++;
    error = null;
    safeNotify();
    try {
      final confirmed = await engine.confirmCheckIn(checkIn);
      if (disposed) return;
      if (confirmed) {
        _pending = _pending
            .where((c) => c.sessionId != checkIn.sessionId)
            .toList();
        await controller.refreshHealth();
      } else {
        error = 'This check-in is no longer available.';
      }
    } catch (_) {
      error = 'Could not confirm. Try again or use the notification.';
    } finally {
      _confirming = false;
      safeNotify();
      unawaited(refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _now = DateTime.now();
      _start();
    } else {
      _refreshRevision++;
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }
}
