import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/features/alarms/alarm_controller.dart';
import 'package:wakeguard/features/alarms/alarm_editor_screen.dart';
import 'package:wakeguard/features/alarms/alarm_repository.dart';
import 'package:wakeguard/features/alarms/alarms_screen.dart';
import 'package:wakeguard/features/alarms/alarms_screen_view_model.dart';
import 'package:wakeguard/features/challenges/qr_sheet.dart';
import 'package:wakeguard/features/health/health_screen.dart';
import 'package:wakeguard/features/health/health_screen_view_model.dart';
import 'package:wakeguard/features/history/history_screen.dart';
import 'package:wakeguard/features/history/history_screen_view_model.dart';
import 'package:wakeguard/features/onboarding/onboarding_screen.dart';
import 'package:wakeguard/features/onboarding/onboarding_screen_view_model.dart';
import 'package:wakeguard/features/settings/settings_controller.dart';
import 'package:wakeguard/features/settings/settings_screen.dart';
import 'package:wakeguard/features/settings/settings_screen_view_model.dart';
import 'package:wakeguard/features/support/support_screen.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/platform/alarm_engine.dart';
import 'package:wakeguard/shared/toast.dart';
import 'package:wakeguard/shared/view_model.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final page in [
      'Alarms',
      'Health',
      'History',
      'Settings',
      'Support',
      'Onboarding',
      'Editor',
      'QR',
    ]) {
      testWidgets(
        '$page fits a small phone with large text in ${brightness.name} mode',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          PackageInfo.setMockInitialValues(
            appName: 'WakeGuard',
            packageName: 'app.wakeguard',
            version: '1.0.0',
            buildNumber: '1',
            buildSignature: '',
          );
          final repository = AlarmRepository();
          await repository.save([
            Alarm(id: 'morning', hour: 7, minute: 0, label: 'Morning'),
          ]);
          final engine = EngineUnavailable();
          final controller = AlarmController(
            engine: engine,
            repository: repository,
          );
          final settings = SettingsController();
          await settings.load();
          await controller.reload();
          await controller.refreshHealth();
          final ViewModel? vm = switch (page) {
            'Alarms' => AlarmsScreenViewModel(controller),
            'Health' => HealthScreenViewModel(controller),
            'History' => HistoryScreenViewModel(controller),
            'Settings' => SettingsScreenViewModel(controller, settings),
            'Onboarding' => OnboardingScreenViewModel(
              controller,
              onDone: () async {},
            ),
            _ => null,
          };
          addTearDown(() {
            vm?.dispose();
            controller.dispose();
            settings.dispose();
          });
          Widget screen() => switch (page) {
            'Alarms' => AlarmsScreen(
              viewModel: vm! as AlarmsScreenViewModel,
              onOpen: (_) async {},
            ),
            'Health' => HealthScreen(viewModel: vm! as HealthScreenViewModel),
            'History' => HistoryScreen(
              viewModel: vm! as HistoryScreenViewModel,
            ),
            'Settings' => SettingsScreen(
              viewModel: vm! as SettingsScreenViewModel,
            ),
            'Support' => const SupportScreen(),
            'Onboarding' => OnboardingScreen(
              viewModel: vm! as OnboardingScreenViewModel,
            ),
            'Editor' => const Scaffold(body: AlarmEditor()),
            _ => const Scaffold(body: QrSheet(value: 'WAKE-UP-CODE')),
          };
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness, useMaterial3: true),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: vm == null
                  ? screen()
                  : ListenableBuilder(
                      listenable: vm,
                      builder: (_, _) => screen(),
                    ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (page == 'Onboarding') {
            expect(find.text('Allow exact alarms'), findsNothing);
          }
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 8; i++) {
            await tester.drag(scrollable, const Offset(0, -400));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
    testWidgets(
      'full-width Undo toast fits large text in ${brightness.name} mode',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAppToast(
                    context,
                    kind: ToastKind.success,
                    message: 'Deleted your morning alarm',
                    detail: 'You can restore it.',
                    actionLabel: 'Undo',
                    onAction: () {},
                  ),
                  child: const Text('Show toast'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Show toast'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Undo'), findsOneWidget);
        final card = find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  const Color(0xFF2E7D32),
        );
        expect(tester.getSize(card).width, 288);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
      },
    );
  }
}
