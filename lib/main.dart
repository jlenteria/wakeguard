import 'dart:async';

import 'package:flutter/material.dart';

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
      // Render immediately. The controller checks the channel and can retry it;
      // a transient first call must not permanently select a no-op engine.
      final engine = MethodChannelEngine();
      runApp(WakeGuardApp(engine: engine, repository: repository));
    },
    (error, stack) {
      // Never silent: a user has an alarm depending on this process.
      debugPrint('WakeGuard fatal: $error\n$stack');
    },
  );
}
