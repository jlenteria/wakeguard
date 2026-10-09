import 'package:flutter/services.dart';

import '../core/alarm.dart';

/// Health signals the UI surfaces so the user can fix them before an alarm
/// silently fails to ring.
enum HealthSeverity { ok, warning, blocking }

class HealthCheck {
  const HealthCheck({
    required this.id,
    required this.label,
    required this.detail,
    required this.severity,
    this.action,
  });

  final String id;
  final String label;
  final String detail;
  final HealthSeverity severity;

  /// Platform-side identifier for a fix action, e.g. `exact_alarm`.
  final String? action;
}

/// What the current platform is actually able to do.
///
/// The UI must never offer a control the platform cannot honour, so this is
/// data rather than a pile of `Platform.isIOS` checks scattered in widgets.
class EngineCapabilities {
  const EngineCapabilities({
    required this.canLoopWhileBackgrounded,
    required this.canLockScreenTakeover,
    required this.canUseCameraInBackground,
    required this.canBypassSilentSwitch,
    required this.pendingSlotCap,
    this.contractVersion = 1,
    this.canPractice = false,
    this.canCheckIn = false,
  });

  /// Android: true (foreground service). iOS: false.
  final bool canLoopWhileBackgrounded;

  /// Android: true (setFullScreenIntent). iOS: false, no public API exists.
  final bool canLockScreenTakeover;

  /// Android: true. iOS: false, camera requires the foreground.
  final bool canUseCameraInBackground;

  /// Android: false — the app does not request Do Not Disturb policy access,
  /// so an alarm rings at whatever volume the user has set. iOS: false too.
  /// Kept as a capability because the ring experience depends on it.
  final bool canBypassSilentSwitch;

  /// Android: effectively unlimited. iOS: 64 pending notifications.
  final int? pendingSlotCap;
  final int contractVersion;
  final bool canPractice;
  final bool canCheckIn;

  bool get hasPendingSlotCap => pendingSlotCap != null;
}

/// Platform-agnostic contract implemented once per platform.
abstract class AlarmEngine {
  Future<void> practice(Alarm alarm);
  Future<void> clearHistory();
  Future<EngineCapabilities> capabilities();

  /// Declares an alarm to the platform and schedules every escalation rung.
  Future<void> schedule(Alarm alarm, DateTime triggerAt);

  Future<void> cancel(String alarmId);

  /// The alarms the platform has actually recorded.
  ///
  /// The native store is what decides whether something rings, so this is read
  /// on every load rather than trusted from cache: an alarm that fired while
  /// the app was closed changes state natively (a one-shot retires itself) and
  /// a mirror that never hears about it keeps offering a switch for an alarm
  /// that can no longer ring.
  Future<List<Alarm>> nativeAlarms();

  /// Most recent dismissals, newest first, as `{at, method}` maps.
  ///
  /// This is the raw material for the wake-up streak: the platform records it
  /// because only the platform sees a dismissal that happens while the Dart
  /// isolate is not running.
  Future<List<Map<String, Object?>>> history();

  Future<void> dismiss(String alarmId, {required String method});

  Future<List<HealthCheck>> health();

  Future<List<String>> notificationsReady();

  /// Shows the platform's runtime permission dialogs. Both platforms require an
  /// explicit grant before an alarm is visible, so this is called from the
  /// preflight rather than at alarm time, when it is too late to be useful.
  Future<bool> requestPermissions();

  /// Plays the bundled alarm ladder through the platform's alarm audio stream
  /// so the user can confirm they can actually hear it. Returns once the whole
  /// sample has played.
  ///
  /// [soundPack] previews one specific tone family so the user can compare the
  /// options before committing to one.
  Future<void> playAudibilitySample({AlarmSoundPack? soundPack});

  /// Stops a running [playAudibilitySample] immediately. Safe to call when
  /// nothing is playing.
  Future<void> stopAudibilitySample();

  /// Opens the platform settings screen that resolves [action].
  ///
  /// Returns null on success, or a human-readable reason when the screen could
  /// not be opened. Returning the reason rather than swallowing it keeps a
  /// broken fix button distinguishable from a working one.
  Future<String?> openFixAction(String action);

  Future<Map<String, Object?>> launchDetails();
}

/// Thrown by [AlarmEngine] implementations for engine-level failures.
///
/// Deliberately not named `PlatformException`: the method channel already
/// throws Flutter's `PlatformException`, and shadowing that name makes the
/// catch clauses in the controller ambiguous.
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

  /// Single boundary between Flutter's channel errors and this app's error type.
  ///
  /// Native failures arrive as [PlatformException] and unimplemented methods as
  /// [MissingPluginException]. Letting those escape would mean every caller had
  /// to know about Flutter internals, so they are translated once here and the
  /// native error code is preserved for the health UI.
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

/// Thrown when a native method is not implemented on the running platform.
/// Both platforms implement the full surface; this exists so a missing handler
/// degrades into a visible UI error instead of a `MissingPluginException`.
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
