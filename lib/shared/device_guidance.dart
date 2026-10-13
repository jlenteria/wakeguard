import 'package:flutter/foundation.dart';

/// Plain-language guidance for the device running the app.
class DeviceGuidance {
  const DeviceGuidance._();

  static String soundTest(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android =>
      'Listen to the alarm tone for 10 seconds. Adjust Alarm volume in your '
          'phone’s sound settings if it is too quiet. To check it with the screen '
          'locked, set a test alarm and lock your phone.',
    TargetPlatform.iOS =>
      'Listen to the alarm tone for 10 seconds. This checks the sound while '
          'WakeGuard is open. To check it with your iPhone locked, set a test alarm '
          'and lock your phone. Silent mode and Focus may silence alarm notifications.',
    _ =>
      'Listen to the alarm tone for 10 seconds. Set a test alarm to check '
          'whether it also sounds when WakeGuard is closed.',
  };

  static String volumeSetup(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android =>
      'Play the alarm tone for 10 seconds. If it is too quiet, raise Alarm '
          'volume in your phone’s sound settings—not music or ringtone volume.',
    TargetPlatform.iOS =>
      'Play the alarm tone for 10 seconds. For scheduled alarms, allow '
          'notification sounds in Settings > Notifications > WakeGuard. '
          'Check Silent mode and Focus too.',
    _ => 'Play the alarm tone for 10 seconds and adjust your device’s volume.',
  };

  static String deliveryAdvice(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android =>
      'Allow alarms in Do Not Disturb and check Alarm volume. If an alarm '
          'arrives late, allow WakeGuard to run without battery restrictions. '
          'Setting names vary by phone brand.',
    TargetPlatform.iOS =>
      'Allow WakeGuard notifications and sounds in your iPhone’s Settings. '
          'Turn off Silent mode and allow WakeGuard in any Focus you use overnight. '
          'Set a test alarm and lock your iPhone to check these settings.',
    _ =>
      'Check notification permissions, sound settings and Do Not Disturb. '
          'Set a test alarm before relying on it.',
  };
}
