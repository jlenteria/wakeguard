import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/features/alarms/alarm_controller.dart';
import 'package:wakeguard/features/alarms/alarm_repository.dart';
import 'package:wakeguard/features/health/health_screen.dart';
import 'package:wakeguard/features/health/health_screen_view_model.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/models/health.dart';
import 'package:wakeguard/platform/alarm_engine.dart';

HealthCheck _check(String id, HealthSeverity severity) => HealthCheck(
  id: id,
  label: '$id setting',
  detail: 'Details for $id',
  severity: severity,
  action: id,
);

class _HealthEngine extends EngineUnavailable {
  List<HealthCheck> checks = [
    _check('passed', HealthSeverity.ok),
    _check('warning', HealthSeverity.warning),
    _check('blocking', HealthSeverity.blocking),
  ];
  bool resolveFix = false;
  int stops = 0;
  int plays = 0;
  @override
  Future<List<HealthCheck>> health() async => checks;
  @override
  Future<String?> openFixAction(String action) async {
    if (resolveFix) {
      checks = [
        for (final c in checks)
          c.id == action ? _check(c.id, HealthSeverity.ok) : c,
      ];
    }
    return null;
  }

  @override
  Future<void> playAudibilitySample({AlarmSoundPack? soundPack}) async {
    plays++;
  }

  @override
  Future<void> stopAudibilitySample() async {
    stops++;
  }
}

void main() {
  late _HealthEngine engine;
  late AlarmController controller;
  late HealthScreenViewModel viewModel;

  Future<void> showHealth(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    engine = _HealthEngine();
    controller = AlarmController(engine: engine, repository: AlarmRepository());
    await controller.refreshHealth();
    viewModel = HealthScreenViewModel(controller);
    addTearDown(() {
      viewModel.dispose();
      controller.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: viewModel,
          builder: (_, _) => HealthScreen(viewModel: viewModel),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'problems come first, passed checks collapse and refresh updates summary',
    (tester) async {
      await showHealth(tester);
      expect(find.text('2 settings need attention'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('blocking setting')).dy,
        lessThan(tester.getTopLeft(find.text('warning setting')).dy),
      );
      expect(find.text('passed setting'), findsNothing);
      await tester.ensureVisible(find.text('Passed checks (1)'));
      await tester.tap(find.text('Passed checks (1)'));
      await tester.pumpAndSettle();
      expect(find.text('passed setting'), findsOneWidget);
      engine.checks = [_check('passed', HealthSeverity.ok)];
      await tester.tap(find.byTooltip('Refresh checks'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 1000));
      await tester.pumpAndSettle();
      expect(find.text('Required checks passed'), findsOneWidget);
    },
  );

  testWidgets(
    'fix feedback distinguishes requested action from verified resolution',
    (tester) async {
      await showHealth(tester);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'blocking setting'),
          matching: find.text('Fix'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Action requested'), findsOneWidget);
      engine.resolveFix = true;
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'blocking setting'),
          matching: find.text('Fix'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Resolved'), findsOneWidget);
      expect(find.text('1 setting needs attention'), findsOneWidget);
    },
  );

  testWidgets('sound test can be stopped and resets after its timeout', (
    tester,
  ) async {
    await showHealth(tester);
    await tester.tap(find.text('Play audibility test'));
    await tester.pump();
    expect(find.text('Stop test'), findsOneWidget);
    expect(engine.plays, 1);
    await tester.tap(find.text('Stop test'));
    await tester.pumpAndSettle();
    expect(engine.stops, 1);
    expect(find.text('Play audibility test'), findsOneWidget);
    await tester.tap(find.text('Play audibility test'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(engine.stops, 2);
    expect(viewModel.playing, isFalse);
  });
}
