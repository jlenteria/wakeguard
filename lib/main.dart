import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/alarm_repository.dart';
import 'platform/alarm_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runZonedGuarded(
    () async {
      final repository = AlarmRepository();
      final engine = await _resolveEngine();
      final details = await engine.launchDetails();
      runApp(
        WakeGuardApp(
          engine: engine,
          repository: repository,
          pendingChallenge: details,
        ),
      );
    },
    (error, stack) {
      // A crash here must never be silent: the user has an alarm depending on
      // this process, and the native watchdog is what recovers it.
      debugPrint('WakeGuard fatal: $error\n$stack');
    },
  );
}

/// Falls back to [EngineUnavailable] rather than throwing so a partially
/// built binary still shows an actionable UI instead of a red screen.
Future<AlarmEngine> _resolveEngine() async {
  try {
    await MethodChannel(MethodChannelEngine.channelName)
        .invokeMethod<void>('capabilities');
    return MethodChannelEngine();
  } on MissingPluginException {
    return EngineUnavailable();
  } catch (_) {
    return EngineUnavailable();
  }
}