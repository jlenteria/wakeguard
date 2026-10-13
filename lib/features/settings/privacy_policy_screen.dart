import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const url = 'https://jlenteria.netlify.app/wakeguard-privacy.html';
  static const contact = 'jlenteria98@gmail.com';
  static const sections = <(String, String)>[
    (
      'About this policy',
      'WakeGuard for Android (com.bling.wakeguard) is developed by Bling Bling. Updated October 13, 2026. Privacy contact: jlenteria98@gmail.com.',
    ),
    (
      'Alarms and local data',
      'Alarm times, labels, challenge choices, QR secrets, object-practice verification, settings, ringing sessions and recent wake-up history are stored in the app’s private storage on your device. WakeGuard has no accounts, ads, developer-operated server or custom analytics service. Android backup and device transfer are disabled for this data.',
    ),
    (
      'Camera and recognition',
      'Camera permission is used while a Face, Object or QR challenge is visible. Frames are processed on-device in memory and are not saved as photos or uploaded by WakeGuard. Object practice stores only whether a supported target was successfully recognised, not a reference photo. Recognition does not identify a person or prove their location.',
    ),
    (
      'Third-party SDK diagnostics',
      'The Android app uses Google ML Kit for on-device face detection, QR scanning and image labeling. Google documents collection of device and app information, per-installation identifiers, performance metrics, API configuration, feature/event information and error codes for diagnostics and usage analytics. These SDK diagnostics may be sent to Google over HTTPS when connectivity is available. Alarm contents and camera frames are not sent by WakeGuard. See developers.google.com/ml-kit/android-data-disclosure and policies.google.com/privacy. This SDK processing is distinct from the app’s local alarm records.',
    ),
    (
      'Sharing, printing and support',
      'Sharing or printing a wake-up QR is optional and user-initiated. The chosen app or print service receives the exported QR and handles it under its own policy. Optional support payments take place through your chosen wallet/bank app; WakeGuard does not receive payment credentials or grant digital features for contributions.',
    ),
    (
      'Permissions and notifications',
      'Camera enables camera challenges; notification and exact-alarm permissions enable alarms and Stay Awake reminders. Full-screen intents display a ringing challenge over the lock screen where permitted. A foreground media service, wake lock and audio controls keep a scheduled alarm audible. Recognition can work offline; SDK diagnostics do not need to complete for an alarm to run.',
    ),
    (
      'Retention and deletion',
      'Local settings and alarms remain until changed, deleted, or app storage is cleared. Recent history is capped at 500 events and can be cleared from History. Uninstalling or clearing Android app storage deletes local app records. Exported QR copies and payment records remain with their recipients. Diagnostics already received by Google are subject to Google’s retention policies and are not erased by clearing this app’s local history.',
    ),
    (
      'Your choices and contact',
      'You may revoke camera/notification permissions in Android Settings, disable or delete alarms, clear history, and choose whether to share, print or contribute. Revoking permissions may prevent the selected challenge or reminder from working. WakeGuard has no online account to delete. For privacy questions, contact jlenteria98@gmail.com. Material changes will be reflected in the policy available in Settings and on the public policy page.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacy policy')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SelectableText(url),
        const SizedBox(height: 20),
        for (final section in sections) ...[
          Text(section.$1, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(section.$2),
          const SizedBox(height: 24),
        ],
      ],
    ),
  );
}
