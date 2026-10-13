import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/alarm.dart';
import 'alarm_repository.dart';
import '../../models/escalation.dart';
import '../../models/wake_up_stats.dart';
import '../../models/reconcile.dart';
import '../../models/health.dart';
import '../../platform/alarm_engine.dart';

enum AlarmSaveFailure { camera, health, storage, engine }

class AlarmSaveResult {
  const AlarmSaveResult.saved() : saved = true, error = null, failure = null;
  const AlarmSaveResult.failed(this.error, this.failure) : saved = false;

  final bool saved;
  final String? error;
  final AlarmSaveFailure? failure;
}

/// Owns alarm state and keeps the Dart mirror and native scheduler in sync; a
/// [ChangeNotifier] that reports errors as state so Health can show them.
class AlarmController extends ChangeNotifier {
  AlarmController({required this.engine, required this.repository})
    : _policy = EscalationPolicy.standard;

  final AlarmEngine engine;
  final AlarmRepository repository;
  final EscalationPolicy _policy;

  List<Alarm> _alarms = const [];
  List<HealthCheck> _checks = const [];
  List<PlannedAlarm> _planned = const [];
  List<Map<String, Object?>> _history = const [];
  bool _loading = true;
  bool _disposed = false;
  bool _audibilityTestPlaying = false;
  Timer? _audibilityTimer;
  String? _fatalError;
  String? _storageError;
  String? _lastError;
  EngineCapabilities? _capabilities;
  Map<String, DateTime> _nativeTriggers = const {};

  /// Tail of the mutation queue; see [_queued].
  Future<void> _mutations = Future<void>.value();

  List<Alarm> get alarms => _alarms;
  List<HealthCheck> get checks => _checks;
  List<PlannedAlarm> get planned => _planned;
  List<Map<String, Object?>> get history => _history;

  /// Streak and totals, computed from the platform's dismissal record.
  WakeUpStats get wakeUpStats => computeWakeUpStats(_history, alarms: _alarms);
  bool get loading => _loading;
  String? get fatalError => _storageError ?? _fatalError;
  String? get lastError => _lastError;
  bool get audibilityTestPlaying => _audibilityTestPlaying;
  EngineCapabilities? get capabilities => _capabilities;

  /// Blocking health checks; saving is refused while any remain.
  List<HealthCheck> get unresolvedChecks =>
      _checks.where((c) => c.severity == HealthSeverity.blocking).toList();

  bool cameraPermissionMissingFor(Alarm alarm) =>
      (alarm.escapes.contains(EscapeKind.face) ||
          alarm.escapes.contains(EscapeKind.object) ||
          alarm.escapes.contains(EscapeKind.qr)) &&
      _checks.any(
        (check) => check.id == 'camera' && check.severity != HealthSeverity.ok,
      );

  /// Alarms dropped by the platform's pending-slot cap; on iOS these will not
  /// ring, so they are surfaced. Empty where there is no cap (Android).
  List<Alarm> get droppedAlarms {
    if (_planned.length >= _alarms.length) return const [];
    final scheduledIds = _planned.map((p) => p.alarm.id).toSet();
    return _alarms
        .where((a) => a.enabled && !scheduledIds.contains(a.id))
        .toList();
  }

  /// Rungs the platform can hold, or null when it has no budget.
  int? get _usableSlots {
    final cap = _capabilities?.pendingSlotCap;
    if (cap == null) return null;
    return cap - EscalationPolicy.iosReservedSlots;
  }

  List<PlannedAlarm> _plan(List<Alarm> alarms) =>
      _policy.plan(alarms, usableSlots: _usableSlots);

  DateTime? nextFireTime(String alarmId) {
    if (_nativeTriggers.containsKey(alarmId)) return _nativeTriggers[alarmId];
    for (final planned in _planned) {
      if (planned.alarm.id == alarmId) return planned.triggerAt;
    }
    return null;
  }

  Future<void> attach() async {
    await reload();
    await refreshHealth();
  }

  /// Clears a fatal error and retries; a dead channel is often just the engine
  /// still starting, and a permanent error screen turns a blip into an uninstall.
  Future<void> retry() async {
    _setState(() {
      _fatalError = null;
      _storageError = null;
      _loading = true;
    });
    await attach();
  }

  Future<void> reload() => _queued(_reload);

  Future<void> _reload() async {
    List<Alarm> alarms;
    try {
      alarms = await repository.load();
      _storageError = null;
    } catch (error) {
      _setState(() {
        _storageError = 'Could not read saved alarms: $error';
        _loading = false;
      });
      return;
    }
    var effective = alarms;

    // The platform store decides what rings, so it wins on enabled state; a
    // failure here must not blank the UI: the mirror still renders.
    try {
      final platform = await engine.nativeAlarms();
      _nativeTriggers = {
        for (final alarm in platform)
          if (alarm.enabled && (alarm.scheduledAtMillis ?? 0) > 0)
            alarm.id: DateTime.fromMillisecondsSinceEpoch(
              alarm.scheduledAtMillis!,
            ),
      };
      final reconciled = reconcileAlarms(
        mirror: alarms,
        native: platform,
        nativeConfigurationAuthoritative:
            defaultTargetPlatform == TargetPlatform.android,
      );
      effective = reconciled.alarms;
      if (reconciled.needsSave) await repository.save(effective);
      for (final alarm in reconciled.toSchedule) {
        await engine.schedule(alarm, alarm.nextOccurrence());
      }
      if (reconciled.toSchedule.isNotEmpty) {
        final confirmed = await engine.nativeAlarms();
        _nativeTriggers = {
          for (final alarm in confirmed)
            if (alarm.enabled && (alarm.scheduledAtMillis ?? 0) > 0)
              alarm.id: DateTime.fromMillisecondsSinceEpoch(
                alarm.scheduledAtMillis!,
              ),
        };
      }
    } on EngineException catch (error) {
      _lastError = 'Could not read native alarms: ${error.message}';
      _nativeTriggers = const {};
    } on MissingPluginException {
      _lastError = 'Native alarm engine is missing.';
      _nativeTriggers = const {};
    } catch (error) {
      _lastError = 'Could not reconcile alarms: $error';
    }

    final planned = _plan(effective);
    _setState(() {
      _alarms = effective;
      _planned = planned;
      _loading = false;
    });
  }

  Future<void> refreshHealth() => _queued(_refreshHealth);

  Future<void> _refreshHealth() async {
    try {
      final capabilities = await engine.capabilities();
      final checks = await engine.health();
      // History is optional: a platform without it costs the streak, not the app.
      _history = await _readHistory();
      _setState(() {
        _capabilities = capabilities;
        _checks = checks;
        _fatalError = null;
        // Re-plan: capabilities may arrive after reload(), and its slot cap must
        // show drops as soon as they are real.
        _planned = _plan(_alarms);
      });
    } on EngineException catch (error) {
      _setState(() => _fatalError = error.message);
    } on MissingPluginException {
      _setState(() => _fatalError = 'Native alarm engine is missing.');
    } catch (error) {
      _setState(() => _fatalError = 'Could not check the alarm engine: $error');
    }
  }

  Future<List<Map<String, Object?>>> _readHistory() async {
    try {
      return await engine.history();
    } catch (error) {
      // A temporary read error must not make an existing streak disappear.
      debugPrint('WakeGuard history refresh failed: $error');
      return _history;
    }
  }

  Future<AlarmSaveResult> upsert(Alarm alarm) => _queued(() => _upsert(alarm));

  AlarmSaveResult _saveFailure(String message, AlarmSaveFailure failure) {
    _setState(() => _lastError = message);
    return AlarmSaveResult.failed(message, failure);
  }

  Future<AlarmSaveResult> _upsert(
    Alarm alarm, {
    bool requireCamera = true,
  }) async {
    _setState(() => _lastError = null);
    await _refreshHealth();
    if (fatalError != null) {
      return _saveFailure(
        'Alarm not saved: $fatalError',
        AlarmSaveFailure.engine,
      );
    }
    if (alarm.enabled && alarm.needsSetup) {
      return _saveFailure(
        'Open this alarm and set up its replacement challenge before enabling it.',
        AlarmSaveFailure.health,
      );
    }
    if (alarm.enabled &&
        alarm.escapes.contains(EscapeKind.object) &&
        !alarm.objectVerified) {
      return _saveFailure(
        'Successfully practice your ${alarm.objectTarget.label.toLowerCase()} before enabling this alarm.',
        AlarmSaveFailure.health,
      );
    }
    if (alarm.enabled && requireCamera && cameraPermissionMissingFor(alarm)) {
      return _saveFailure(
        'Alarm not saved. Enable camera permission in Health for Face/Object/QR challenges.',
        AlarmSaveFailure.camera,
      );
    }
    if (alarm.enabled && unresolvedChecks.isNotEmpty) {
      return _saveFailure(
        'Alarm not saved: ${unresolvedChecks.map((c) => c.label).join(', ')}. Open Health to fix it.',
        AlarmSaveFailure.health,
      );
    }
    final previous = List<Alarm>.of(_alarms);
    final exists = _alarms.any((a) => a.id == alarm.id);
    final next = exists
        ? _alarms.map((a) => a.id == alarm.id ? alarm : a).toList()
        : [..._alarms, alarm];
    try {
      await repository.save(next);
    } catch (error) {
      return _saveFailure(
        'Could not save alarm: $error',
        AlarmSaveFailure.storage,
      );
    }

    try {
      if (alarm.enabled) {
        await engine.schedule(alarm, alarm.nextOccurrence());
      } else {
        await engine.cancel(alarm.id);
      }
    } catch (error) {
      // Do not leave the failed edit in the mirror as if it were armed.
      try {
        await repository.save(previous);
      } catch (rollbackError) {
        _setState(
          () =>
              _storageError = 'Could not restore saved alarms: $rollbackError',
        );
      }
      await _reload();
      final confirmed = _alarms.where((value) => value.id == alarm.id);
      if (error is EngineException &&
          error.code == 'TIMEOUT' &&
          confirmed.isNotEmpty &&
          sameAlarmConfiguration(confirmed.first, alarm) &&
          (!alarm.enabled || _nativeTriggers.containsKey(alarm.id))) {
        _setState(() => _lastError = null);
        return const AlarmSaveResult.saved();
      }
      return _saveFailure(
        'Native schedule failed: $error. Your draft was not saved.',
        AlarmSaveFailure.engine,
      );
    }
    await _reload();
    // A successful native mutation plus durable mirror write is the save result;
    // a later history/read refresh must not turn it into a false save failure.
    return const AlarmSaveResult.saved();
  }

  Future<void> setEnabled(Alarm alarm, bool enabled) => _queued(() async {
    await _refreshHealth();
    if (enabled && cameraPermissionMissingFor(alarm)) {
      const message =
          'Enable camera permission in Health before turning on this camera challenge.';
      _setState(() => _lastError = message);
      throw StateError(message);
    }
    if (enabled && unresolvedChecks.isNotEmpty) {
      final message =
          'Cannot enable alarm: ${unresolvedChecks.map((c) => c.label).join(', ')}. Open Health to fix it.';
      _setState(() => _lastError = message);
      throw StateError(message);
    }
    final current = _alarms.firstWhere(
      (a) => a.id == alarm.id,
      orElse: () => alarm,
    );
    final result = await _upsert(
      current.copyWith(enabled: enabled, skipUntilMillis: 0),
      requireCamera: enabled,
    );
    if (!result.saved) throw StateError(result.error!);
  });

  Future<void> duplicate(Alarm alarm) => _queued(() async {
    final current = _alarms.firstWhere(
      (a) => a.id == alarm.id,
      orElse: () => alarm,
    );
    await _upsert(
      current.copyWith(
        id: Alarm.generateId(),
        label: '${current.label} (copy)',
        enabled: false,
        skipUntilMillis: 0,
      ),
    );
    if (_lastError != null) throw StateError(_lastError!);
  });

  Future<void> skipNext(Alarm alarm) => _queued(() async {
    final current = _alarms.firstWhere(
      (a) => a.id == alarm.id,
      orElse: () => alarm,
    );
    if (!current.enabled || !current.isRepeating) return;
    await _upsert(
      current.copyWith(
        skipUntilMillis: current.nextOccurrence().millisecondsSinceEpoch,
      ),
    );
    if (_lastError != null) throw StateError(_lastError!);
  });

  Future<void> clearHistory() => _queued(() async {
    await engine.clearHistory();
    _setState(() => _history = const []);
  });

  Future<void> refreshHistory() => _queued(() async {
    final history = await engine.history();
    _setState(() => _history = history);
  });

  Future<void> restoreNext(Alarm alarm) => _queued(() async {
    final current = _alarms.firstWhere(
      (a) => a.id == alarm.id,
      orElse: () => alarm,
    );
    await _upsert(current.copyWith(skipUntilMillis: 0));
    if (_lastError != null) throw StateError(_lastError!);
  });

  Future<bool> delete(Alarm alarm) => _queued(() => _delete(alarm));

  Future<bool> _delete(Alarm alarm) async {
    final next = _alarms.where((a) => a.id != alarm.id).toList();
    try {
      await repository.save(next);
    } catch (error) {
      _setState(() => _lastError = 'Could not delete alarm: $error');
      return false;
    }
    var cancelled = true;
    try {
      await engine.cancel(alarm.id);
    } on EngineException catch (error) {
      cancelled = false;
      _setState(() => _lastError = 'Could not cancel alarm: ${error.message}');
    } on MissingPluginException {
      cancelled = false;
      _setState(() => _lastError = 'Native alarm engine is missing.');
    }
    // On cancel failure, reload re-imports the still-armed alarm from native.
    await _reload();
    if (cancelled) _setState(() => _lastError = null);
    await _refreshHealth();
    return cancelled && !_alarms.any((a) => a.id == alarm.id);
  }

  Future<void> runPreflight() async {
    if (_audibilityTestPlaying || _disposed) return;
    _setState(() {
      _lastError = null;
      _audibilityTestPlaying = true;
    });
    _audibilityTimer = Timer(const Duration(seconds: 10), () {
      unawaited(stopAudibilitySample());
    });
    try {
      await engine.playAudibilitySample();
    } on EngineException catch (error) {
      await stopAudibilitySample();
      _setState(() => _lastError = error.message);
    } catch (error) {
      await stopAudibilitySample();
      _setState(() => _lastError = 'Could not play the sound test: $error');
    }
    await refreshHealth();
  }

  /// Silences the audibility sample early so leaving the screen it started from
  /// does not let it ring on; best effort, an unimplemented method is fine.
  Future<void> stopAudibilitySample() async {
    _audibilityTimer?.cancel();
    _audibilityTimer = null;
    _setState(() => _audibilityTestPlaying = false);
    try {
      await engine.stopAudibilitySample();
    } on EngineException {
      // Nothing to report: the sample times out on its own anyway.
    } on MissingPluginException {
      // Engine absent or not translated yet.
    }
  }

  /// Opens the platform settings screen for [action]; a failure is surfaced,
  /// since a settings screen that silently does nothing looks broken.
  Future<String?> openFix(String action) async {
    try {
      final failure = await engine.openFixAction(action);
      await refreshHealth();
      return failure;
    } on EngineException catch (error) {
      _setState(() => _lastError = error.message);
      await refreshHealth();
      return error.message;
    }
  }

  void clearError() => _setState(() => _lastError = null);

  /// Runs [operation] after queued mutations settle, so two read-modify-writes
  /// of the alarm list cannot interleave and resurrect a deleted alarm.
  Future<T> _queued<T>(Future<T> Function() operation) {
    final run = _mutations.then((_) => operation());
    // The queue must survive failures, or one rejected save blocks all later ones.
    _mutations = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  @override
  void dispose() {
    _audibilityTimer?.cancel();
    _disposed = true;
    super.dispose();
  }

  void _setState(VoidCallback mutate) {
    if (_disposed) return;
    mutate();
    notifyListeners();
  }
}
