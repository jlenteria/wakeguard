# Android release: com.bling.wakeguard

Android only. iOS implementation and release verification are deferred.

## Signing

Release builds require a real upload keystore. The build reads
`android/key.properties` (gitignored), or these environment variables:
`WAKEGUARD_KEYSTORE`, `WAKEGUARD_KEY_ALIAS`, `WAKEGUARD_STORE_PASSWORD`,
`WAKEGUARD_KEY_PASSWORD`. Relative keystore paths resolve from `android/`.

A new local upload key can be created once with:

```sh
python3 tool/create_android_upload_key.py
```

The helper refuses to replace existing files, generates an RSA upload key, and
saves private signing credentials without printing passwords. Back up
`android/app/upload-keystore.jks` and `android/key.properties` securely before
publishing. Never commit either file. To use an existing key, configure it using
`android/key.properties.example`. Enable Play App Signing in Play Console.

## Build

Install the Android 36 SDK and the Flutter toolchain required by `pubspec.yaml`.

```sh
flutter build apk --release
flutter build appbundle --release
```

Equivalent Makefile shortcuts: `make release-key` (once), `make release`
(signing preflight, analysis/source checks, tests, then signed AAB, APK and bundle
verification, in that order even with `make -j release`).
`make release-verify` can also verify an existing AAB independently.

Signing preflight and verification require JDK 17+ (`JAVA=/path/to/java` may be
overridden). They read the same signing properties/environment variables as
Gradle. Preflight opens the keystore and private key and checks certificate
validity. Verification reads every payload entry to check its digest and requires
its signer to match the configured upload certificate. Unsigned, partially signed,
modified or differently signed bundles fail; a self-signed upload certificate is
accepted without needing a public certificate authority. Passwords are not printed
or placed on the command line.

Bundle: `build/app/outputs/bundle/release/app-release.aab`.
APK: `build/app/outputs/flutter-apk/app-release.apk`.
`make build-apk-release` and `make release` also create a versioned copy,
`build/app/outputs/flutter-apk/WakeGuard-<version>+<build>.apk`, using the version
in `pubspec.yaml` (for example, `WakeGuard-1.0.1+2.apk`). `make install-release`
installs that versioned APK. Flutter's original output is retained for its build tooling.
Namespace, application ID and Kotlin package: `com.bling.wakeguard`.
The previous `app.wakeguard` application ID is a separate installed app; Android
does not transfer its private alarm records to this application ID.

The release explicitly targets API 36 and does not use debug signing. Confirm the
resolved manifest, signature, arm64 packaging and 16 KB native-library compatibility
on the actual artifact/Play pre-launch report. Bundled ML Kit models need device
validation even if the build succeeds. Complete `docs/VERIFICATION.md`.

## Publish the privacy page

Copy `docs/wakeguard-privacy.html` into the published root of your Render website
(for a site with a build pipeline, usually its `public/` directory), then deploy
that website normally. Verify this URL serves the policy rather than a 404 or the
site's single-page-app fallback:

https://jlenteria.onrender.com/wakeguard-privacy.html

The matching in-app policy is in Settings -> Privacy policy.
Privacy contact: jlenteria98@gmail.com.
This repository prepares the HTML; it does not deploy the separate Render site.

## Play Console

- Complete store listing, screenshots, content rating, audience and app-access declarations.
- Complete full-screen-intent and mediaPlayback foreground-service declarations,
  including the required demonstration video.
- Complete Data Safety using the resolved SDK versions and Google's ML Kit data
  disclosure. Do not claim "no data collected" solely because camera processing
  is offline: SDK diagnostics include device/app information, installation IDs,
  performance/configuration and feature/error events. Camera frames and alarm
  contents are not uploaded by WakeGuard.
- Support QR (Settings -> Support): voluntary person-to-person tip, no digital
  features, rewards or unlocks, and nothing is gated behind it. Play's Payments
  policy exempts "peer-to-peer payments" and "tax exempt donations" from Play
  Billing, but an individual's tip is not clearly either, and reviewers can reject
  external payment prompts. This is a real review risk. If the app is rejected for
  it, remove the Support screen entry point from the Play build and resubmit; do not
  appeal by adding any reward. Do not mention the QR or tipping in the store listing.
- For a qualifying new personal developer account, complete the required closed
  test with 12 continuously opted-in testers for 14 days, then apply for production access.

### Declaration cheat sheet

- **Full-screen intent (`USE_FULL_SCREEN_INTENT`):** core function is an alarm clock;
  the ring/challenge screen must appear over the lock screen at the alarm time.
  Demo video: schedule an alarm, lock the phone, show the challenge appearing on
  the lock screen, complete it. With Stay Awake enabled, also demonstrate the
  related native Still up? response page on the lock screen and its I'm up action.
- **Foreground service `mediaPlayback`:** `RingingService` loops the alarm tone while
  the alarm rings and the challenge is pending. Demo video: the ringing alarm with
  its persistent notification, then dismissal stopping the service.
- **Exact alarms:** `USE_EXACT_ALARM` is used (alarm clock app); no Play declaration
  form is expected, but the core functionality must be alarm clock.
- **Camera:** runtime permission, only for Face/Object/QR challenges; optional
  (`android.hardware.camera.front` is `required="false"`).
- **Data Safety:** collection by ML Kit SDKs (device/app info, installation IDs,
  diagnostics). Not collected by WakeGuard: accounts, alarm contents, camera frames.
  Privacy policy URL: https://jlenteria.onrender.com/wakeguard-privacy.html

### Per-upload checklist

1. Bump `version:` in `pubspec.yaml` (`1.0.0+1` is the first upload; every later
   upload needs a higher build number after the `+`).
2. `make release`, then `make release-verify`.
3. Complete `docs/VERIFICATION.md` on real devices (including an API 24-27 device
   and a lower-end device) and record the results.
4. Back up `android/app/upload-keystore.jks` and `android/key.properties` offline.
5. Upload `build/app/outputs/bundle/release/app-release.aab` to an internal or
   closed test track first.

Production readiness requires the signed artifact and completed device results;
source changes, a successful debug build, or the existence of this checklist are
not release approval.
