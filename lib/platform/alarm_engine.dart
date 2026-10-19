import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/alarm.dart';
import '../models/check_in.dart';
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

  Future<void> dismiss(
    String alarmId, {
    required String method,
    required String sessionId,
  });

  Future<List<HealthCheck>> health();

  Future<List<String>> notificationsReady();

  /// Shows runtime permission dialogs; called from preflight, not alarm time.
  Future<bool> requestPermissions();

  /// Plays the bundled alarm ladder on the alarm audio stream so the user can
  /// confirm audibility; [soundPack] previews one tone family.
  Future<void> playAudibilitySample({
    AlarmSoundPack? soundPack,
    bool vibrate = false,
  });

  /// Stops a running [playAudibilitySample]; safe when nothing is playing.
  Future<void> stopAudibilitySample();

  /// Opens the platform settings screen for [action]; returns null on success or
  /// a reason on failure, so a broken fix button stays distinguishable.
  Future<String?> openFixAction(String action);

  Future<Map<String, Object?>> launchDetails();
}

/// Verification is a device-local result of an actual native practice scan.
extension ObjectVerification on AlarmEngine {
  Future<bool> objectTargetVerified(String target) async {
    final engine = this;
    if (engine is! MethodChannelEngine) return false;
    return await engine._invoke<bool>('objectTargetVerified', {
          'target': target,
        }) ??
        false;
  }
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

/// Optional native check-in presentation; other platforms need not implement it.
abstract interface class CheckInEngine {
  Future<List<PendingCheckIn>> pendingCheckIns();
  Future<bool> confirmCheckIn(PendingCheckIn checkIn);
}

/// An uploaded alarm tone the platform has copied into its own storage.
class PickedSound {
  const PickedSound({required this.id, required this.name});

  /// Opaque reference stored on the alarm; the file itself never leaves the platform.
  final String id;

  /// The original file name, for display.
  final String name;
}

/// Optional: choosing and previewing an uploaded alarm tone. Android only today.
abstract interface class CustomSoundEngine {
  bool get supportsCustomSounds;

  /// The device's own alarm sounds (RingtoneManager TYPE_ALARM), for the picker.
  Future<List<PickedSound>> listSystemSounds();

  /// Copies a device sound into app storage so it rings reliably. Returns the
  /// stored reference; throws [EngineException] when the sound is unusable.
  Future<PickedSound> importSystemSound(String uri);

  /// Opens the system file picker; null when the user cancels. Throws
  /// [EngineException] when the file is unusable (too large, not audio).
  Future<PickedSound?> pickCustomSound();

  /// Plays the uploaded tone on the alarm stream; stop with
  /// [AlarmEngine.stopAudibilitySample].
  Future<void> previewCustomSound(String id, {bool vibrate = false});
}

class MethodChannelEngine
    implements AlarmEngine, CheckInEngine, CustomSoundEngine {
  MethodChannelEngine({MethodChannel? channel})
    : _channel =
          channel ??
          MethodChannel(
            defaultTargetPlatform == TargetPlatform.iOS
                ? 'app.wakeguard/alarm'
                : channelName,
          );

  static const channelName = 'com.bling.wakeguard/alarm';

  final MethodChannel _channel;

  @override
  Future<List<PendingCheckIn>> pendingCheckIns() async {
    if (defaultTargetPlatform != TargetPlatform.android) return const [];
    final raw = await _invoke<List<Object?>>('pendingCheckIns') ?? const [];
    return raw
        .cast<Map<Object?, Object?>>()
        .map(PendingCheckIn.fromJson)
        .toList();
  }

  @override
  Future<bool> confirmCheckIn(PendingCheckIn checkIn) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    return await _invoke<bool>('confirmCheckIn', {
          'id': checkIn.alarmId,
          'sessionId': checkIn.sessionId,
        }) ??
        false;
  }

  @override
  bool get supportsCustomSounds =>
      defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<List<PickedSound>> listSystemSounds() async {
    if (!supportsCustomSounds) return const [];
    final raw = await _invoke<List<Object?>>('listSystemSounds') ?? const [];
    return raw
        .cast<Map<Object?, Object?>>()
        .map((item) {
          return PickedSound(
            id: item['id'] as String? ?? '',
            name: item['name'] as String? ?? 'Sound',
          );
        })
        .where((sound) => sound.id.isNotEmpty)
        .toList();
  }

  @override
  Future<PickedSound> importSystemSound(String uri) async {
    if (!supportsCustomSounds) {
      throw EngineException(
        'UNSUPPORTED',
        'Custom sounds are available on Android only.',
      );
    }
    final raw = await _invoke<Map<Object?, Object?>>('importSystemSound', {
      'uri': uri,
    });
    final id = raw?['id'] as String?;
    if (id == null || id.isEmpty) {
      throw EngineException('CUSTOM_SOUND', 'Could not use that sound.');
    }
    return PickedSound(id: id, name: raw?['name'] as String? ?? 'Sound');
  }

  @override
  Future<PickedSound?> pickCustomSound() async {
    if (!supportsCustomSounds) {
      throw EngineException(
        'UNSUPPORTED',
        'Custom sounds are available on Android only.',
      );
    }
    final raw = await _invoke<Map<Object?, Object?>>('pickCustomSound');
    final id = raw?['id'] as String?;
    if (id == null || id.isEmpty) return null;
    return PickedSound(id: id, name: raw?['name'] as String? ?? 'Custom sound');
  }

  @override
  Future<void> previewCustomSound(String id, {bool vibrate = false}) =>
      _invoke<void>('previewCustomSound', {'id': id, 'vibrate': vibrate});

  @override
  Future<void> practice(Alarm alarm) =>
      _invoke<void>('practice', alarm.toJson());

  @override
  Future<void> clearHistory() => _invoke<void>('clearHistory');

  /// Translates native errors once, preserving the code for the health UI.
  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments).timeout(
        switch (method) {
          'schedule' || 'cancel' => const Duration(seconds: 30),
          // A person is choosing a file in the system picker.
          'pickCustomSound' => const Duration(minutes: 10),
          _ => const Duration(seconds: 10),
        },
      );
    } on TimeoutException {
      throw EngineException(
        'TIMEOUT',
        'The alarm engine did not respond to $method. Retry when the device is responsive.',
      );
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
  Future<void> dismiss(
    String alarmId, {
    required String method,
    required String sessionId,
  }) => _invoke<void>('dismiss', {
    'id': alarmId,
    'method': method,
    'sessionId': sessionId,
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
  Future<void> playAudibilitySample({
    AlarmSoundPack? soundPack,
    bool vibrate = false,
  }) => _invoke<void>('playAudibilitySample', {
    if (soundPack != null) 'soundPack': soundPack.name,
    'vibrate': vibrate,
  });

  @override
  Future<void> stopAudibilitySample() => _invoke<void>('stopAudibilitySample');

  @override
  Future<String?> openFixAction(String action) =>
      _invoke<String>('openFixAction', {'action': action});

  @override
  Future<Map<String, Object?>> launchDetails() async {
    final raw =
        await _invoke<Map<Object?, Object?>>('launchDetails') ?? const {};
    return Map<String, Object?>.from(raw);
  }
}

/// Degrades a missing native handler into a visible UI error, not a
/// `MissingPluginException`.
class EngineUnavailable implements AlarmEngine {
  Never _unavailable() => throw EngineException(
    'UNAVAILABLE',
    'Alarms are not available on this device. No alarm has been set.',
  );
  @override
  Future<void> practice(Alarm alarm) async {
    throw EngineException(
      'UNAVAILABLE',
      'Challenge practice is available on Android phones only.',
    );
  }

  @override
  Future<void> clearHistory() async => _unavailable();
  @override
  Future<void> cancel(String alarmId) async => _unavailable();

  @override
  Future<List<Alarm>> nativeAlarms() async => _unavailable();

  @override
  Future<List<Map<String, Object?>>> history() async => const [];

  @override
  Future<EngineCapabilities> capabilities() async => _unavailable();

  @override
  Future<void> dismiss(
    String alarmId, {
    required String method,
    required String sessionId,
  }) async => _unavailable();

  @override
  Future<List<HealthCheck>> health() async => _unavailable();

  @override
  Future<Map<String, Object?>> launchDetails() async => const {};

  @override
  Future<String?> openFixAction(String action) async =>
      'Alarm settings are not available on this device.';

  @override
  Future<bool> requestPermissions() async => false;

  @override
  Future<void> playAudibilitySample({
    AlarmSoundPack? soundPack,
    bool vibrate = false,
  }) async => _unavailable();

  @override
  Future<void> stopAudibilitySample() async {}

  @override
  Future<List<String>> notificationsReady() async => ['engine'];

  @override
  Future<void> schedule(Alarm alarm, DateTime triggerAt) async =>
      _unavailable();
}
