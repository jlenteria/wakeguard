# WakeGuard

An offline alarm clock for people who dismiss an alarm and fall back asleep.
Choose a wake challenge, practise it, and optionally ask WakeGuard to check
you are still up a few minutes later. Alarm readiness is visible before bed.

- **Android is the product.** The iOS target exists but is out of scope for the
  Play Store work.
- **Free, no ads, no analytics, no accounts.** Everything is stored on device.
- **Camera** is used only while a wake challenge is on screen. Frames are never
  saved or transmitted.

## Features

- **Simple / Challenge / Get out of bed presets:** tap to stop, a camera-free
  memory pattern, or a QR code placed away from bed. Face actions are also
  available. The two-minute hold always remains an escape.
- **Stay Awake:** opt into a check-in 3, 5 or 10 minutes after dismissal. Confirm
  with “I'm up” during the one-minute grace period; an unanswered check-in
  produces at most one follow-up alarm, with no snooze or further check-ins.
- **Practice:** use the real native challenge without scheduling, playing alarm
  audio, adding history or changing the next alarm. Back/Exit leaves practice.
- **Flexible mornings:** daily, selected days or one-time alarms; per-alarm
  snooze; skip the next repeat and resume automatically; duplicate switched off.
- **History:** started, snoozed, dismissed, missed and check-in outcomes with
  duration and snooze count. Streaks use completed interactions, excluding
  unscheduled weekdays for the current repeating schedule. History is bounded
  and can be deleted from the History tab.
- **Readiness:** blocking exact-alarm, notification and alarm-volume checks;
  camera/full-screen guidance; sound previews; next-date/time save feedback.
- **Privacy:** no account, ads or analytics; local processing and explicit
  Android backup/transfer exclusions. Uninstalling deletes local records.

## What makes an alarm ring

Three layers, each one able to recover a ring the previous one lost:

1. `AlarmManager.setAlarmClock` — exempt from Doze and App Standby, which is
   the single most important property on Android.
2. **Watchdog rungs** at 45 s / 2 min / 5 min / 10 min
   (`setExactAndAllowWhileIdle`, armed relative to each ring's start) restart
   the foreground service if an OEM killer takes it down mid-ring.
3. A **fallback notification** if Android refuses the foreground-service start,
   so the failure is visible instead of silent.

The wake challenge (`AlarmRingActivity`) is deliberately a plain Android
Activity, never a Flutter route: dismissing an alarm must not depend on the
Dart isolate booting. Each alarm carries the escapes it offers — face actions,
tap to stop, pattern, QR — and any one of them works, plus a two-minute hold that is always
available regardless of configuration.

## Layout

```
lib/
  core/        Alarm model, repository, reconcile, escalation, settings, streaks
  platform/    AlarmEngine contract + MethodChannel implementation
  ui/          Alarm editor, Health, History, Settings, onboarding
android/       Scheduler, persisted sessions, check-ins, ringing, health checks
```

The Dart side keeps a **mirror** of the alarm set for fast rendering; the
native store decides what actually rings. They are reconciled on every load
(`lib/core/reconcile.dart`): the platform wins on `enabled`, alarms the mirror
knows but the platform lost are re-scheduled, and alarms only the platform
knows are imported rather than dropped.

Details are in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Running

```sh
flutter pub get
flutter run            # debug; signing uses the debug key
flutter test
flutter analyze
```

Release signing is **not** set up yet: `android/app/build.gradle.kts` uses the
debug key and has `isMinifyEnabled = false`. Production signing is required;
release shrinking should be evaluated with the camera models and sound assets.

## Play Store status

Done:

- Device-admin and battery-optimisation permissions removed (Play rejects the
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` pattern).
- `SCHEDULE_EXACT_ALARM` limited to `maxSdkVersion="32"`; `USE_EXACT_ALARM`
  is the alarm-clock permission on 13+.
- No `ACCESS_NOTIFICATION_POLICY` (DND bypass needs a weak justification).
- Foreground service is `mediaPlayback`, not `specialUse`.
- `android.hardware.camera.front` declared `required="false"` so camera-less
  devices are not filtered out.
- Blocking vs. warning severities: only exact alarms, alarm volume and
  notification permission block a save; full-screen intent and camera are
  warnings.

Still to do before submission:

- Release signing (R8/minify off for now), store listing assets, `allowBackup`
  privacy policy URL (required even with no data collection because
  of the camera), and the closed-testing requirement (12 testers, 14 days).

## Constraints

`opencode.json` denies `flutter analyze/build/run/test`, `dart analyze/run/
test/compile`, `./gradlew`, `gradle` and `xcodebuild`. Changes made by an
agent in this repo are therefore **unverified**; run the commands above
yourself before trusting them. See [`docs/VERIFICATION.md`](docs/VERIFICATION.md)
for native regression tests and device acceptance scenarios. Source parsing is
not evidence that a lock-screen alarm works on a device.
