import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/platform/alarm_engine.dart';
import 'package:wakeguard/features/alarms/alarm_editor_screen.dart';
import 'package:wakeguard/features/challenges/qr_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('QR secret can be generated and the code renders', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: QrSheet(value: 'ABC-1234')),
      ),
    );
    await tester.pumpAndSettle();

    // qr_flutter renders failures as blank squares, so assert a real QrPainter with a version.
    expect(find.text('Could not render this code.'), findsNothing);

    final paint = tester.widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(QrImageView),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = paint.map((w) => w.painter).whereType<QrPainter>().single;
    expect(painter.version, greaterThan(0));

    // Plain-text fallback is intentional: the path that works when the code will not scan.
    expect(find.text('ABC-1234'), findsOneWidget);
  });

  testWidgets('editor generates a secret that is not empty or trivially short', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AlarmEditor())),
    );
    await tester.pumpAndSettle();

    // QR is opt-in: turning the chip on must produce a code, not an empty field.
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

    expect(find.text('Show QR code'), findsOneWidget);
  });

  testWidgets('two generated secrets differ', (tester) async {
    final secrets = <String>{};
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AlarmEditor(key: UniqueKey())),
        ),
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

  testWidgets('editor offers every sound family with a preview control', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AlarmEditor())),
    );
    await tester.pumpAndSettle();

    for (final pack in AlarmSoundPack.values) {
      expect(find.text(pack.label), findsOneWidget);
    }
    // One preview button per family: the point of the picker is comparing first.
    expect(find.byIcon(Icons.volume_up_outlined), findsNWidgets(4));
  });

  testWidgets('new QR alarms reuse the shared code across editor sessions', (
    tester,
  ) async {
    for (var i = 0; i < 2; i++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlarmEditor(
              key: UniqueKey(),
              sharedQrValue: 'SHARED-WAKE-UP',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilterChip, 'QR code'));
      await tester.tap(find.widgetWithText(FilterChip, 'QR code'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'QR code secret'),
      );
      expect(field.controller!.text, 'SHARED-WAKE-UP');
      expect(find.text('Show wake-up QR'), findsOneWidget);
    }
  });

  testWidgets('existing QR stays custom until explicitly switched to shared', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlarmEditor(
            sharedQrValue: 'SHARED-WAKE-UP',
            existing: Alarm(
              id: 'old',
              hour: 7,
              minute: 0,
              label: 'Old QR alarm',
              qrValue: 'OLD-PRINTED-CODE',
              escapes: const {EscapeKind.qr},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'QR code secret'),
    );
    expect(field.controller!.text, 'OLD-PRINTED-CODE');
    await tester.ensureVisible(find.text('Use shared wake-up QR'));
    await tester.tap(find.text('Use shared wake-up QR'));
    await tester.pumpAndSettle();
    expect(field.controller!.text, 'SHARED-WAKE-UP');
  });

  testWidgets('saving returns an alarm carrying the chosen sound pack', (
    tester,
  ) async {
    // The sheet exceeds the default 800x600 surface, so the save button is off-screen.
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

  testWidgets(
    'get-out-of-bed preset provides a code, no snooze and one check-in',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AlarmEditor())),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Get out of bed'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'QR code secret'),
      );
      expect(field.controller!.text, isNotEmpty);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'No snooze'))
            .selected,
        isTrue,
      );
      // Snooze and check-in both have a five-minute choice; only check-in is selected.
      expect(
        tester
            .widgetList<ChoiceChip>(find.widgetWithText(ChoiceChip, '5 min'))
            .where((c) => c.selected)
            .length,
        1,
      );
    },
  );

  testWidgets('practice uses the chosen draft without scheduling an alarm', (
    tester,
  ) async {
    final engine = _PracticeEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AlarmEditor(engine: engine)),
      ),
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Simple'));
    final button = find.text('Practice this challenge — no alarm scheduled');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(engine.practiced?.escapes, {EscapeKind.tap});
    expect(engine.scheduled, 0);
  });
}

class _PracticeEngine extends EngineUnavailable {
  Alarm? practiced;
  int scheduled = 0;
  @override
  Future<void> practice(Alarm alarm) async {
    practiced = alarm;
  }

  @override
  Future<void> schedule(Alarm alarm, DateTime triggerAt) async {
    scheduled++;
  }
}
