import 'package:flutter/services.dart';

import '../models/alarm.dart';
import '../models/health.dart';

/// Platform-agnostic contract implemented once per platform.
abstract class AlarmEngine {
  Future<void> practice(Alarm alarm);
  Future<void> clearHistory();
  Future<EngineCapabilities> capabilities();

  /// Declares an alarm to the platform and schedules every escalation rung.
  Future<void> schedule(Alarm alarm, DateTime triggerAt);

  Future<void> cancel(String alarmId);

  /// The platform's own alarm record, read every load: a native state change
  /// (e.g. a one-shot retiring) must not be masked by a stale mirror.
  Future<List<Alarm>> nativeAlarms();

  /// Recent dismissals, newest first, as `{at, method}` maps; only the platform
  /// sees dismissals that happen while the Dart isolate is not running.
  Future<List<Map<String, Object?>>> history();

  Future<void> dismiss(String alarmId, {required String method});

  Future<List<HealthCheck>> health();

  Future<List<String>> notificationsReady();

  /// Shows runtime permission dialogs; called from preflight, not alarm time.
  Future<bool> requestPermissions();

  /// Plays the bundled alarm ladder on the alarm audio stream so the user can
  /// confirm audibility; [soundPack] previews one tone family.
  Future<void> playAudibilitySample({AlarmSoundPack? soundPack});

  /// Stops a running [playAudibilitySample]; safe when nothing is playing.
  Future<void> stopAudibilitySample();

  /// Opens the platform settings screen for [action]; returns null on success or
  /// a reason on failure, so a broken fix button stays distinguishable.
  Future<String?> openFixAction(String action);

  Future<Map<String, Object?>> launchDetails();
}

/// Thrown for engine-level failures; deliberately not `PlatformException`, whose
/// name the method channel already uses, making catch clauses ambiguous.
class EngineException implements Exception {
  EngineException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'EngineException($code, $message)';
}

class MethodChannelEngine implements AlarmEngine {
  MethodChannelEngine({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'app.wakeguard/alarm';

  final MethodChannel _channel;

  @override
  Future<void> practice(Alarm alarm) => _invoke<void>('practice', alarm.toJson());

  @override
  Future<void> clearHistory() => _invoke<void>('clearHistory');

  /// Translates native errors once, preserving the code for the health UI.
  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw EngineException(error.code, error.message ?? 'Native call failed');
    } on MissingPluginException {
      throw EngineException(
        'MISSING_PLUGIN',
        'No native alarm engine is registered for $method',
      );
    }
  }

  @override
  Future<EngineCapabilities> capabilities() async {
    final raw = await _invoke<Map<Object?, Object?>>('capabilities');
    if (raw == null) {
      throw EngineException('NO_CAPABILITIES', 'Native channel is absent');
    }
    return EngineCapabilities(
      canLoopWhileBackgrounded: raw['canLoopWhileBackgrounded'] == true,
      canLockScreenTakeover: raw['canLockScreenTakeover'] == true,
      canUseCameraInBackground: raw['canUseCameraInBackground'] == true,
      canBypassSilentSwitch: raw['canBypassSilentSwitch'] == true,
      pendingSlotCap: raw['pendingSlotCap'] as int?,
      contractVersion: (raw['contractVersion'] as num?)?.toInt() ?? 1,
      canPractice: raw['canPractice'] == true,
      canCheckIn: raw['canCheckIn'] == true,
    );
  }

  @override
  Future<void> schedule(Alarm alarm, DateTime triggerAt) async {
    await _invoke<void>('schedule', {
      ...alarm.toJson(),
      'contractVersion': 2,
      'triggerAtMillis': triggerAt.millisecondsSinceEpoch,
      'weekdays': alarm.weekdays.toList(),
    });
  }

  @override
  Future<void> cancel(String alarmId) =>
      _invoke<void>('cancel', {'id': alarmId});

  @override
  Future<List<Alarm>> nativeAlarms() async {
    final raw = await _invoke<List<Object?>>('alarms') ?? const [];
    return raw
        .cast<Map<Object?, Object?>>()
        .map((item) => Alarm.fromJson(Map<String, Object?>.from(item)))
        .toList();
  }

  @override
  Future<List<Map<String, Object?>>> history() async {
    final raw = await _invoke<List<Object?>>('history') ?? const [];
    return raw
        .cast<Map<Object?, Object?>>()
        .map((item) => Map<String, Object?>.from(item))
        .toList();
  }

  @override
  Future<void> dismiss(String alarmId, {required String method}) =>
      _invoke<void>('dismiss', {
        'id': alarmId,
        'method': method,
      });

  @override
  Future<List<HealthCheck>> health() async {
    final raw = await _invoke<List<Object?>>('health') ?? const [];
    return raw.cast<Map<Object?, Object?>>().map((item) {
      final map = Map<String, Object?>.from(item);
      return HealthCheck(
        id: map['id'] as String? ?? 'unknown',
        label: map['label'] as String? ?? 'Check',
        detail: map['detail'] as String? ?? '',
        severity: HealthSeverity.values.firstWhere(
          (s) => s.name == map['severity'],
          orElse: () => HealthSeverity.warning,
        ),
        action: map['action'] as String?,
      );
    }).toList();
  }

  @override
  Future<List<String>> notificationsReady() async {
    final raw = await _invoke<List<Object?>>('notificationsReady') ?? const [];
    return raw.cast<String>();
  }

  @override
  Future<bool> requestPermissions() async =>
      await _invoke<bool>('requestPermissions') ?? false;

  @override
  Future<void> playAudibilitySample({AlarmSoundPack? soundPack}) => _invoke<void>(
        'playAudibilitySample',
        {if (soundPack != null) 'soundPack': soundPack.name},
      );

  @override
  Future<void> stopAudibilitySample() => _invoke<void>('stopAudibilitySample');

  @override
  Future<String?> openFixAction(String action) =>
      _invoke<String>('openFixAction', {'action': action});

  @override
  Future<Map<String, Object?>> launchDetails() async {
    final raw = await _invoke<Map<Object?, Object?>>('launchDetails') ?? const {};
    return Map<String, Object?>.from(raw);
  }
}

/// Degrades a missing native handler into a visible UI error, not a
/// `MissingPluginException`.
class EngineUnavailable implements AlarmEngine {
  @override
  Future<void> practice(Alarm alarm) async { throw EngineException('UNAVAILABLE', 'Challenge practice requires Android.'); }
  @override
  Future<void> clearHistory() async {}
  @override
  Future<void> cancel(String alarmId) async {}

  @override
  Future<List<Alarm>> nativeAlarms() async => const [];

  @override
  Future<List<Map<String, Object?>>> history() async => const [];

  @override
  Future<EngineCapabilities> capabilities() async => const EngineCapabilities(
        canLoopWhileBackgrounded: false,
        canLockScreenTakeover: false,
        canUseCameraInBackground: false,
        canBypassSilentSwitch: false,
        pendingSlotCap: 64,
      );

  @override
  Future<void> dismiss(String alarmId, {required String method}) async {}

  @override
  Future<List<HealthCheck>> health() async => const [];

  @override
  Future<Map<String, Object?>> launchDetails() async => const {};

  @override
  Future<String?> openFixAction(String action) async => 'No native engine';

  @override
  Future<bool> requestPermissions() async => false;

  @override
  Future<void> playAudibilitySample({AlarmSoundPack? soundPack}) async {}

  @override
  Future<void> stopAudibilitySample() async {}

  @override
  Future<List<String>> notificationsReady() async => const [];

  @override
  Future<void> schedule(Alarm alarm, DateTime triggerAt) async {}
}
