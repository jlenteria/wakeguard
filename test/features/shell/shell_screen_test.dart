import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/features/alarms/alarm_controller.dart';
import 'package:wakeguard/features/alarms/alarm_repository.dart';
import 'package:wakeguard/features/alarms/alarm_editor_screen.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/features/settings/settings_controller.dart';
import 'package:wakeguard/features/shell/shell_screen.dart';
import 'package:wakeguard/features/shell/shell_screen_view_model.dart';
import 'package:wakeguard/models/health.dart';
import 'package:wakeguard/platform/alarm_engine.dart';

class _CameraEngine extends EngineUnavailable {
  @override
  Future<EngineCapabilities> capabilities() async => const EngineCapabilities(
    canLoopWhileBackgrounded: true,
    canLockScreenTakeover: true,
    canUseCameraInBackground: true,
    canBypassSilentSwitch: false,
    pendingSlotCap: null,
  );
  bool cameraGranted = false;
  final List<Alarm> store = [];

  @override
  Future<List<Alarm>> nativeAlarms() async => List.of(store);

  @override
  Future<void> schedule(Alarm alarm, DateTime triggerAt) async {
    store.removeWhere((value) => value.id == alarm.id);
    store.add(alarm);
  }

  @override
  Future<List<HealthCheck>> health() async => [
    HealthCheck(
      id: 'camera',
      label: 'Camera',
      detail: 'Needed for face and QR challenges',
      severity: cameraGranted ? HealthSeverity.ok : HealthSeverity.warning,
      action: cameraGranted ? null : 'camera',
    ),
  ];

  @override
  Future<String?> openFixAction(String action) async {
    cameraGranted = true;
    return null;
  }
}

void main() {
  testWidgets(
    'saving a camera draft returns to Alarms and clears Health return',
    (tester) async {
      tester.view.physicalSize = const Size(420, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'wakeguard.onboardingDone': true,
      });
      final engine = _CameraEngine();
      final controller = AlarmController(
        engine: engine,
        repository: AlarmRepository(),
      );
      final settings = SettingsController();
      await settings.load();
      await controller.reload();
      await controller.refreshHealth();
      final shell = ShellScreenViewModel(
        engine: engine,
        controller: controller,
        settings: settings,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ListenableBuilder(
              listenable: shell,
              builder: (_, _) => ShellScreen(viewModel: shell),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final openEditor = tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Add New Alarm'),
            )
            .onPressed!;
        openEditor();
        openEditor();
        await tester.pumpAndSettle();
        expect(find.byType(AlarmEditor), findsOneWidget);
        // The editor list builds lazily, so scroll until Save really exists.
        await tester.scrollUntilVisible(
          find.text('Save alarm'),
          300,
          scrollable: find
              .descendant(
                of: find.byType(AlarmEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save alarm'));
        await tester.pumpAndSettle();
        expect(shell.tab, 1);
        expect(shell.pendingCameraDraft, isNotNull);
        await tester.scrollUntilVisible(find.text('Return to alarm'), 150);
        expect(find.text('Return to alarm'), findsOneWidget);

        await tester.scrollUntilVisible(find.text('Fix'), 150);
        await tester.tap(find.text('Fix'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Return to alarm'), -150);
        await tester.tap(find.text('Return to alarm'));
        await tester.pumpAndSettle();
        // The editor list builds lazily, so scroll until Save really exists.
        await tester.scrollUntilVisible(
          find.text('Save alarm'),
          300,
          scrollable: find
              .descendant(
                of: find.byType(AlarmEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save alarm'));
        await tester.pumpAndSettle();

        expect(controller.alarms, hasLength(1));
        expect(shell.tab, 0);
        expect(shell.pendingCameraDraft, isNull);
        expect(shell.cameFromAlarm, isFalse);
        await tester.tap(find.text('Health'));
        await tester.pumpAndSettle();
        expect(find.text('Return to alarm'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        shell.dispose();
        controller.dispose();
        settings.dispose();
      }
    },
  );
}
