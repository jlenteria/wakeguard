# WakeGuard task runner. Run `make` or `make help` for the target list.
#
# Overridable variables:
#   FLUTTER  flutter binary        (default: flutter)
#   DART     dart binary           (default: dart)
#   PYTHON   python interpreter    (default: python3)
#   ADB      adb binary            (default: adb)
#   DEVICE   flutter run -d target (default: unset, uses an attached device)

.DEFAULT_GOAL := help
SHELL := /bin/sh
FLUTTER ?= flutter
DART ?= dart
PYTHON ?= python3
ADB ?= adb

APK := build/app/outputs/flutter-apk/app-release.apk
APK-DEBUG := build/app/outputs/flutter-apk/app-debug.apk
AAB := build/app/outputs/bundle/release/app-release.aab
GRADLEW := ./android/gradlew -p android

.PHONY: help setup get upgrade clean doctor devices run run-release analyze \
	format format-check test test-native verify removable check audit \
	icons alarms assets build-apk build-aab build-ios install uninstall \
	logcat logcat-alarm forward

help:
	@echo "WakeGuard targets"
	@echo ""
	@echo "  Setup"
	@echo "    make setup            Fetch Dart dependencies (flutter pub get)"
	@echo "    make get              Alias for setup"
	@echo "    make upgrade          Upgrade dependencies within constraints"
	@echo "    make clean            Remove build artifacts (flutter clean)"
	@echo "    make doctor           Show Flutter toolchain diagnostics"
	@echo "    make devices          List attached Flutter devices"
	@echo ""
	@echo "  Run"
	@echo "    make run              Run in debug (DEVICE=<id> to pick a device)"
	@echo "    make run-release      Run a release build on a device"
	@echo ""
	@echo "  Checks"
	@echo "    make analyze          Static analysis (flutter analyze)"
	@echo "    make format           Apply dart format to lib/ and test/"
	@echo "    make format-check     Fail if any Dart file is unformatted"
	@echo "    make test             Run Flutter/Dart tests"
	@echo "    make test-native      Run Android unit tests (gradlew)"
	@echo "    make verify           Run tool/verify_source.py"
	@echo "    make removable        Assert no uninstall-resisting capabilities"
	@echo "    make check            analyze + format-check + verify + removable"
	@echo "    make audit            check + test + test-native"
	@echo ""
	@echo "  Assets"
	@echo "    make icons            Regenerate branding + Android/iOS icons"
	@echo "    make alarms           Regenerate alarm tones for both platforms"
	@echo "    make assets           Regenerate icons and alarm tones"
	@echo ""
	@echo "  Build"
	@echo "    make build-apk        Build a debug APK"
	@echo "    make build-apk-release Build a signed release APK"
	@echo "    make build-aab        Build a release App Bundle"
	@echo "    make build-ios        Build a release iOS app (no codesign)"
	@echo ""
	@echo "  Device"
	@echo "    make install          Install the release APK over the current build"
	@echo "    make uninstall        Remove the app from the device"
	@echo "    make logcat           Tail WakeGuard/alarm system logs"
	@echo "    make logcat-alarm     Tail alarm-manager logs only"
	@echo "    make forward          Forward Flutter observatory-style ports (optional)"
	@echo ""
	@echo "  Variables: FLUTTER DART PYTHON ADB DEVICE"

# --- Setup -------------------------------------------------------------------

setup get:
	$(FLUTTER) pub get

upgrade:
	$(FLUTTER) pub upgrade

clean:
	$(FLUTTER) clean

doctor:
	$(FLUTTER) doctor -v

devices:
	$(FLUTTER) devices

# --- Run ---------------------------------------------------------------------

run:
	$(FLUTTER) run $(if $(DEVICE),-d $(DEVICE),)

run-release:
	$(FLUTTER) run --release $(if $(DEVICE),-d $(DEVICE),)

# --- Checks ------------------------------------------------------------------

analyze:
	$(FLUTTER) analyze

format:
	$(DART) format lib test

format-check:
	$(DART) format --output=none --set-exit-if-changed lib test

test:
	$(FLUTTER) test

test-native:
	$(GRADLEW) :app:testDebugUnitTest

verify:
	$(PYTHON) tool/verify_source.py

removable:
	$(PYTHON) tool/check_removable.py

check: analyze format-check verify removable

audit: check test test-native

# --- Assets ------------------------------------------------------------------

icons:
	$(PYTHON) tool/generate_icons.py
	$(PYTHON) tool/generate_ios_icons.py

alarms:
	$(PYTHON) tool/generate_alarms.py
	$(PYTHON) tool/generate_checkin_sound.py

assets: icons alarms

# --- Build -------------------------------------------------------------------

build-apk:
	$(FLUTTER) build apk --debug

build-apk-release:
	$(FLUTTER) build apk --release

build-aab:
	$(FLUTTER) build appbundle --release

build-ios:
	$(FLUTTER) build ios --debug --no-codesign

build-ios-release:
	$(FLUTTER) build ios --release --no-codesign

# --- Device ------------------------------------------------------------------

install:
	$(ADB) install -r $(APK-DEBUG)

install-release:
	$(ADB) install -r $(APK)

uninstall:
	$(ADB) uninstall com.bling.wakeguard

logcat:
	$(ADB) logcat -s WakeGuard AlarmManager ActivityManager

logcat-alarm:
	$(ADB) logcat -s AlarmManager

forward:
	$(ADB) forward tcp:5353 tcp:5353
