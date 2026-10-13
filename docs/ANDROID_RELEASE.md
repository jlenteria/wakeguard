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

Bundle: `build/app/outputs/bundle/release/app-release.aab`.
APK: `build/app/outputs/flutter-apk/app-release.apk`.
Namespace, application ID and Kotlin package: `com.bling.wakeguard`.
The previous `app.wakeguard` application ID is a separate installed app; Android
does not transfer its private alarm records to this application ID.

The release explicitly targets API 36 and does not use debug signing. Confirm the
resolved manifest, signature, arm64 packaging and 16 KB native-library compatibility
on the actual artifact/Play pre-launch report. Bundled ML Kit models need device
validation even if the build succeeds. Complete `docs/VERIFICATION.md`.

## Publish the privacy page

Copy `docs/wakeguard-privacy.html` into the published root of your Netlify website
(for a site with a build pipeline, usually its `public/` directory), then deploy
that website normally. Verify this URL serves the policy rather than a 404 or the
site's single-page-app fallback:

https://jlenteria.netlify.app/wakeguard-privacy.html

The matching in-app policy is in Settings -> Privacy policy.
Privacy contact: jlenteria98@gmail.com.
This repository prepares the HTML; it does not deploy the separate Netlify site.

## Play Console

- Complete store listing, screenshots, content rating, audience and app-access declarations.
- Complete full-screen-intent and mediaPlayback foreground-service declarations,
  including the required demonstration video.
- Complete Data Safety using the resolved SDK versions and Google's ML Kit data
  disclosure. Do not claim "no data collected" solely because camera processing
  is offline: SDK diagnostics include device/app information, installation IDs,
  performance/configuration and feature/error events. Camera frames and alarm
  contents are not uploaded by WakeGuard.
- Support QR contributions grant no digital features. Keep the arrangement within
  the direct-contribution exception: 100% to the creator, no digital rewards.
- For a qualifying new personal developer account, complete the required closed
  test with 12 continuously opted-in testers for 14 days, then apply for production access.

Production readiness requires the signed artifact and completed device results;
source changes, a successful debug build, or the existence of this checklist are
not release approval.
