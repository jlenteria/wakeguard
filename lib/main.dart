import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'features/alarms/alarm_repository.dart';
import 'platform/alarm_engine.dart';

void main() {
  runZonedGuarded(
    () async {
      // Initialize inside the guarded zone: runApp below runs here, and the
      // binding must be created in the same zone or Flutter reports a mismatch.
      WidgetsFlutterBinding.ensureInitialized();
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
      // Never silent: a user has an alarm depending on this process.
      debugPrint('WakeGuard fatal: $error\n$stack');
    },
  );
}

/// Falls back to [EngineUnavailable] so a partial binary still shows a usable UI.
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