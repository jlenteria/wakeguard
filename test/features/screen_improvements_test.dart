import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/features/alarms/alarm_controller.dart';
import 'package:wakeguard/features/alarms/alarm_repository.dart';
import 'package:wakeguard/features/alarms/alarms_screen.dart';
import 'package:wakeguard/features/alarms/alarms_screen_view_model.dart';
import 'package:wakeguard/features/challenges/qr_sheet.dart';
import 'package:wakeguard/features/history/history_screen.dart';
import 'package:wakeguard/features/history/history_screen_view_model.dart';
import 'package:wakeguard/features/settings/settings_controller.dart';
import 'package:wakeguard/features/settings/settings_screen.dart';
import 'package:wakeguard/features/settings/settings_screen_view_model.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/models/health.dart';
import 'package:wakeguard/platform/alarm_engine.dart';
import 'package:wakeguard/shared/brand.dart';

class _Engine extends EngineUnavailable {
  @override
  Future<EngineCapabilities> capabilities() async => const EngineCapabilities(
    canLoopWhileBackgrounded: true,
    canLockScreenTakeover: true,
    canUseCameraInBackground: true,
    canBypassSilentSwitch: false,
    pendingSlotCap: null,
  );
  List<Alarm> store = [];
  List<Map<String, Object?>> events = [];
  Completer<void>? scheduleGate;
  bool failHistory = false;
  int schedules = 0;
  @override
  Future<List<Alarm>> nativeAlarms() async => List.of(store);
  @override
  Future<void> cancel(String alarmId) async {
    store.removeWhere((alarm) => alarm.id == alarmId);
  }

  @override
  Future<void> schedule(Alarm alarm, DateTime triggerAt) async {
    schedules++;
    await scheduleGate?.future;
    store.removeWhere((a) => a.id == alarm.id);
    store.add(alarm);
  }

  @override
  Future<List<Map<String, Object?>>> history() async {
    if (failHistory) throw EngineException('HISTORY', 'History unavailable');
    return events;
  }

  @override
  Future<List<HealthCheck>> health() async => const [
    HealthCheck(
      id: 'camera',
      label: 'Camera permission',
      detail: 'Needed for camera challenges',
      severity: HealthSeverity.warning,
    ),
  ];
}

void main() {
  late _Engine engine;
  late AlarmController controller;

  Future<void> initialize({List<Alarm> alarms = const []}) async {
    SharedPreferences.setMockInitialValues({});
    engine = _Engine()..store = List.of(alarms);
    final repository = AlarmRepository();
    await repository.save(alarms);
    controller = AlarmController(engine: engine, repository: repository);
    await controller.reload();
    await controller.refreshHealth();
    addTearDown(controller.dispose);
  }

  Future<void> showAlarms(WidgetTester tester) async {
    final vm = AlarmsScreenViewModel(controller);
    addTearDown(vm.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: vm,
          builder: (_, _) => AlarmsScreen(viewModel: vm, onOpen: (_) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'all-off message and readiness warning appear, busy switch cannot repeat',
    (tester) async {
      await initialize(
        alarms: [
          Alarm(
            id: 'a',
            hour: 7,
            minute: 0,
            label: 'Morning',
            enabled: false,
            escapes: const {EscapeKind.tap},
          ),
        ],
      );
      await showAlarms(tester);
      expect(find.text('Your alarm needs attention'), findsOneWidget);
      expect(find.textContaining('No alarms enabled.'), findsOneWidget);
      final gate = Completer<void>();
      engine.scheduleGate = gate;
      // The clock above the list pushes the row down; bring it into view.
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(engine.schedules, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
      expect(find.byKey(const ValueKey('next-alarm-caption')), findsOneWidget);
    },
  );

  testWidgets('deleted alarm can still be undone after six seconds', (
    tester,
  ) async {
    await initialize(
      alarms: [
        Alarm(
          id: 'undo',
          hour: 7,
          minute: 0,
          label: 'Morning',
          escapes: const {EscapeKind.tap},
        ),
      ],
    );
    await showAlarms(tester);
    await tester.scrollUntilVisible(find.byType(Dismissible), 200);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Dismissible), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(controller.alarms, isEmpty);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(controller.alarms.single.id, 'undo');
    expect(engine.store.single.id, 'undo');
  });

  testWidgets('next alarm caption identifies the soonest alarm and its date', (
    tester,
  ) async {
    await initialize(
      alarms: [
        Alarm(
          id: 'next',
          hour: 7,
          minute: 0,
          label: 'Work',
          escapes: const {EscapeKind.tap},
        ),
      ],
    );
    await showAlarms(tester);
    final at = controller.nextFireTime('next')!;
    final context = tester.element(find.byType(AlarmsScreen));
    final now = DateTime.now();
    final days =
        (DateTime(at.year, at.month, at.day)
                    .difference(DateTime(now.year, now.month, now.day))
                    .inHours /
                24)
            .round();
    final day = days <= 0
        ? 'today'
        : days == 1
        ? 'tomorrow'
        : 'on ${MaterialLocalizations.of(context).formatMediumDate(at)}';
    final caption = find.byKey(const ValueKey('next-alarm-caption'));
    expect(caption, findsOneWidget);
    expect(
      find.descendant(
        of: caption,
        matching: find.textContaining('Next alarm $day '),
      ),
      findsOneWidget,
    );
    // The hero names the soonest alarm under its time.
    expect(find.text('Work'), findsOneWidget);
  });

  testWidgets('alarm rows are rounded surface cards', (
    tester,
  ) async {
    await initialize(
      alarms: [
        Alarm(
          id: 'row',
          hour: 7,
          minute: 0,
          label: 'Morning',
          escapes: const {EscapeKind.tap},
        ),
      ],
    );
    await showAlarms(tester);
    await tester.scrollUntilVisible(find.byType(Dismissible), 200);
    await tester.pumpAndSettle();
    final card = tester.widget<SurfaceCard>(
      find.descendant(
        of: find.byType(Dismissible),
        matching: find.byType(SurfaceCard),
      ),
    );
    expect(card.radius, greaterThanOrEqualTo(28));
  });

  testWidgets(
    'history sorts and groups dates, names challenges, preserves data on refresh failure',
    (tester) async {
      await initialize();
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 8);
      final yesterday = DateTime(now.year, now.month, now.day - 1, 8);
      engine.events = [
        {
          'at': yesterday.millisecondsSinceEpoch,
          'label': 'Earlier',
          'event': 'missed',
        },
        {
          'at': today.millisecondsSinceEpoch,
          'label': 'Morning',
          'event': 'dismissed',
          'method': 'face',
        },
      ];
      await controller.refreshHistory();
      final vm = HistoryScreenViewModel(controller);
      addTearDown(vm.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: vm,
            builder: (_, _) => HistoryScreen(viewModel: vm),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Today')).dy,
        lessThan(tester.getTopLeft(find.text('Yesterday')).dy),
      );
      expect(find.textContaining('Face challenge'), findsOneWidget);
      engine.failHistory = true;
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(find.text('Could not refresh history'), findsOneWidget);
      expect(vm.entries, hasLength(2));
    },
  );

  testWidgets(
    'settings shows package version and prevents repeated QR sheets',
    (tester) async {
      await initialize();
      PackageInfo.setMockInitialValues(
        appName: 'WakeGuard',
        packageName: 'com.bling.wakeguard',
        version: '1.2.3',
        buildNumber: '42',
        buildSignature: '',
      );
      final settings = SettingsController();
      await settings.load();
      final vm = SettingsScreenViewModel(controller, settings);
      addTearDown(() {
        vm.dispose();
        settings.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: vm,
            builder: (_, _) => SettingsScreen(viewModel: vm),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The settings list builds lazily; scroll until About exists.
      await tester.scrollUntilVisible(find.text('Version 1.2.3 (42)'), 200);
      expect(find.text('Wake-ups'), findsNothing);
      await tester.ensureVisible(find.text('Show wake-up QR'));
      // Two events before rebuilding must still open only one sheet.
      final openQr = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Show wake-up QR'),
          )
          .onPressed!;
      openQr();
      openQr();
      await tester.pumpAndSettle();
      expect(find.byType(QrSheet), findsOneWidget);
      expect(vm.openingQr, isTrue);
      expect(vm.loadingQr, isFalse);
      Navigator.of(tester.element(find.byType(QrSheet))).pop();
      await tester.pumpAndSettle();
      expect(vm.openingQr, isFalse);
    },
  );
}
