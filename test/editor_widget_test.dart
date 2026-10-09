import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/core/alarm.dart';
import 'package:wakeguard/platform/alarm_engine.dart';
import 'package:wakeguard/ui/alarm_editor.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('QR secret can be generated and the code renders', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: QrSheet(value: 'ABC-1234'))),
    );
    await tester.pumpAndSettle();

    // qr_flutter renders an encode failure as a blank square of the same size,
    // so "a widget appeared" proves nothing. The error state is a Column; the
    // success state is a QrPainter. Assert the painter exists and carries a
    // real version, which is what makes the square scannable.
    expect(find.text('Could not render this code.'), findsNothing);

    final paint = tester.widgetList<CustomPaint>(
      find.descendant(of: find.byType(QrImageView), matching: find.byType(CustomPaint)),
    );
    final painter = paint.map((w) => w.painter).whereType<QrPainter>().single;
    expect(painter.version, greaterThan(0));

    // The plain-text fallback is intentional: it is the path that still works
    // when the code will not scan.
    expect(find.text('ABC-1234'), findsOneWidget);
  });

  testWidgets('editor generates a secret that is not empty or trivially short',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AlarmEditor())),
    );
    await tester.pumpAndSettle();

    // QR is opt-in: a code only exists once the escape is chosen, and turning
    // the chip on must produce one rather than a field with nothing in it.
    await tester.ensureVisible(find.widgetWithText(FilterChip, 'QR code'));
    await tester.tap(find.widgetWithText(FilterChip, 'QR code'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byIcon(Icons.qr_code_2_outlined));
    await tester.tap(find.byIcon(Icons.qr_code_2_outlined));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'QR code secret'),
    );
    final secret = field.controller!.text;
    expect(secret, isNotEmpty);
    // 16 letters + 4 digits plus the separator.
    expect(secret.length, greaterThanOrEqualTo(20));

    // The "show" affordance only appears once there is something to show.
    expect(find.text('Show QR code'), findsOneWidget);
  });

  testWidgets('two generated secrets differ', (tester) async {
    final secrets = <String>{};
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AlarmEditor(key: UniqueKey()))),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilterChip, 'QR code'));
      await tester.tap(find.widgetWithText(FilterChip, 'QR code'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byIcon(Icons.qr_code_2_outlined));
      await tester.tap(find.byIcon(Icons.qr_code_2_outlined));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'QR code secret'),
      );
      secrets.add(field.controller!.text);
    }
    expect(secrets.length, 3, reason: 'Random.secure must not repeat');
  });

  testWidgets('editor offers every sound family with a preview control',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AlarmEditor())),
    );
    await tester.pumpAndSettle();

    for (final pack in AlarmSoundPack.values) {
      expect(find.text(pack.label), findsOneWidget);
    }
    // A preview button per family: the point of the picker is being able to
    // compare before committing.
    expect(find.byIcon(Icons.volume_up_outlined), findsNWidgets(4));
  });

  testWidgets('saving returns an alarm carrying the chosen sound pack',
      (tester) async {
    // The editor is a scrollable sheet taller than the 800x600 test surface, so
    // the save button sits off-screen unless the viewport is phone-sized.
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Alarm? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await showModalBottomSheet<Alarm>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const AlarmEditor(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text(AlarmSoundPack.gong.label));
    await tester.tap(find.text(AlarmSoundPack.gong.label));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save alarm'));
    await tester.tap(find.text('Save alarm'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.soundPack, AlarmSoundPack.gong);
  });

  testWidgets('get-out-of-bed preset provides a code, no snooze and one check-in', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AlarmEditor())));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Get out of bed'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.widgetWithText(TextField, 'QR code secret'));
    expect(field.controller!.text, isNotEmpty);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'No snooze')).selected, isTrue);
    // Snooze and check-in both have a five-minute choice; only check-in is selected.
    expect(tester.widgetList<ChoiceChip>(find.widgetWithText(ChoiceChip, '5 min')).where((c) => c.selected).length, 1);
  });

  testWidgets('practice uses the chosen draft without scheduling an alarm', (tester) async {
    final engine = _PracticeEngine();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AlarmEditor(engine: engine))));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Simple'));
    final button = find.text('Practise this challenge — no alarm scheduled');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(engine.practised?.escapes, {EscapeKind.tap});
    expect(engine.scheduled, 0);
  });
}

class _PracticeEngine extends EngineUnavailable {
  Alarm? practised;
  int scheduled = 0;
  @override
  Future<void> practice(Alarm alarm) async { practised = alarm; }
  @override
  Future<void> schedule(Alarm alarm, DateTime triggerAt) async { scheduled++; }
}
