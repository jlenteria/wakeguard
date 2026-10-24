import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/shared/choice_pill.dart';
import 'package:wakeguard/platform/alarm_engine.dart';
import 'package:wakeguard/features/alarms/alarm_editor_screen.dart';
import 'package:wakeguard/features/challenges/qr_sheet.dart';

void main() {
  Future<void> reveal(WidgetTester tester, Finder finder, double delta) async {
    await tester.scrollUntilVisible(
      finder,
      delta,
      // The outermost scrollable is the editor list. (A TextField adds its own
      // inner Scrollable, which would otherwise be picked up by .first.)
      scrollable: find.byType(Scrollable).first,
    );
    // Bring the row fully on screen and let the scroll settle, so taps land.
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('selected options keep the card background, no tint', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AlarmEditor())),
    );
    await tester.pumpAndSettle();
    // Quick setup presets are ListTiles; the selected one must not tint its row.
    final simple = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Simple'),
    );
    expect(simple.selectedTileColor, Colors.transparent);
  });

  testWidgets('a focused field is kept above the keyboard', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AlarmEditor())),
    );
    await tester.pumpAndSettle();

    // Focus the label by hand (it is no longer autofocused), then the keyboard.
    final label = find.widgetWithText(TextField, 'Label');
    await reveal(tester, label, 250);
    await tester.tap(label);
    await tester.pumpAndSettle();
    const keyboard = 300.0;
    tester.view.viewInsets = FakeViewPadding(
      bottom: tester.view.devicePixelRatio * keyboard,
    );
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    final logicalHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final keyboardTop = logicalHeight - keyboard;
    final field = tester.getRect(find.widgetWithText(TextField, 'Label'));
    expect(field.bottom, lessThanOrEqualTo(keyboardTop + 1));
  });

  testWidgets('Face steps sit under the Face choice, only while it is on', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AlarmEditor(engine: _PickerEngine())),
      ),
    );
    await tester.pumpAndSettle();

    final face = find.widgetWithText(ListTile, 'Face check');
    await reveal(tester, face, 250);
    bool stepsShown() =>
        find.text('Face challenge steps').evaluate().isNotEmpty;

    // Whatever the default, the steps follow the Face switch exactly.
    final onByDefault = stepsShown();
    if (onByDefault) {
      expect(find.text('Gentle (1)'), findsOneWidget);
    }

    await tester.tap(face);
    await tester.pumpAndSettle();
    expect(stepsShown(), !onByDefault);

    await tester.tap(find.widgetWithText(ListTile, 'Face check'));
    await tester.pumpAndSettle();
    expect(stepsShown(), onByDefault);
  });

  testWidgets('the time card says it is tappable and opens the picker', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AlarmEditor())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tap to change time'), findsOneWidget);
    expect(find.text('ALARM TIME'), findsOneWidget);

    // The presets now sit above the time card, so bring it into view first.
    await tester.ensureVisible(find.text('Tap to change time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tap to change time'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
  });

  testWidgets('the label is a card with a hint', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AlarmEditor())),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.widgetWithText(TextField, 'Label'), 250);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.label_outline), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Label'), findsOneWidget);

    // Not focused on open, so no keyboard jumps up.
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Label'))
          .autofocus,
      isFalse,
    );
    // Tapping the field gives it focus, so the focused outline is painted.
    await tester.tap(find.widgetWithText(TextField, 'Label'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    OutlineInputBorder? focused() {
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Label'),
      );
      return field.decoration?.focusedBorder as OutlineInputBorder?;
    }

    // No outline at rest, a visible one when focused.
    final decoration = tester
        .widget<TextField>(find.widgetWithText(TextField, 'Label'))
        .decoration!;
    expect(
      (decoration.enabledBorder as OutlineInputBorder).borderSide.style,
      BorderStyle.none,
    );
    expect(focused()!.borderSide.width, greaterThan(0));
    expect(focused()!.borderSide.style, BorderStyle.solid);
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
    expect(find.textContaining('Could not show this QR code.'), findsNothing);

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
    await reveal(tester, find.widgetWithText(ListTile, 'QR code'), 250);
    await tester.ensureVisible(find.widgetWithText(ListTile, 'QR code'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'QR code'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byIcon(Icons.qr_code_2_outlined));
    await tester.tap(find.byIcon(Icons.qr_code_2_outlined));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'QR code value'),
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
      await reveal(tester, find.widgetWithText(ListTile, 'QR code'), 250);
      await tester.ensureVisible(find.widgetWithText(ListTile, 'QR code'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'QR code'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byIcon(Icons.qr_code_2_outlined));
      await tester.tap(find.byIcon(Icons.qr_code_2_outlined));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'QR code value'),
      );
      secrets.add(field.controller!.text);
    }
    expect(secrets.length, 3, reason: 'Random.secure must not repeat');
  });

  testWidgets('sound picker lists the phone tones, not the bundled packs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AlarmEditor(engine: _PickerEngine())),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.widgetWithText(ListTile, 'Sound');
    await reveal(tester, row, 250);
    // Nothing is listed until the Sound row is tapped.
    expect(find.text('Aurora'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('Aurora'), findsOneWidget);
    expect(find.text('Nebula'), findsOneWidget);
    expect(find.text('Upload your own sound'), findsOneWidget);
    expect(find.text('Alarm tone'), findsOneWidget);
    // Vibration lives in the same sheet.
    expect(find.widgetWithText(SwitchListTile, 'Vibration'), findsOneWidget);

    // The four bundled packs are no longer offered as a choice.
    for (final pack in AlarmSoundPack.values) {
      expect(find.text(pack.label), findsNothing);
    }
  });

  testWidgets('the alarm tone page clears the Android navigation bar', (
    tester,
  ) async {
    tester.view.viewPadding = const FakeViewPadding(bottom: 60);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AlarmEditor(engine: _PickerEngine())),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.widgetWithText(ListTile, 'Sound'), 250);
    await tester.tap(find.widgetWithText(ListTile, 'Sound'));
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    // The page adds the system inset (scaled by DPR) on top of its own margin.
    expect(list.padding!.resolve(TextDirection.ltr).bottom, greaterThan(32));
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
      await reveal(tester, find.widgetWithText(ListTile, 'QR code'), 250);
      await tester.ensureVisible(find.widgetWithText(ListTile, 'QR code'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'QR code'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'QR code value'),
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
    // The list builds lazily, so scroll down to the QR field first.
    await reveal(tester, find.widgetWithText(TextField, 'QR code value'), 250);
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'QR code value'),
    );
    expect(field.controller!.text, 'OLD-PRINTED-CODE');
    await reveal(tester, find.text('Use shared wake-up QR'), 250);
    await tester.ensureVisible(find.text('Use shared wake-up QR'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use shared wake-up QR'));
    await tester.pumpAndSettle();
    expect(field.controller!.text, 'SHARED-WAKE-UP');
  });

  testWidgets('after uploading a sound you can switch back to a device tone', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AlarmEditor(engine: _PickerEngine())),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.widgetWithText(ListTile, 'Sound');
    await reveal(tester, row, 250);
    await tester.tap(row);
    await tester.pumpAndSettle();

    Radio<String> radio(String value) => tester.widget<Radio<String>>(
      find.byWidgetPredicate((w) => w is Radio<String> && w.value == value),
    );
    String? chosen() => RadioGroup.maybeOf<String>(
      tester.element(find.byType(Radio<String>).first),
    )?.groupValue;

    await tester.tap(find.text('Upload your own sound'));
    await tester.pumpAndSettle();
    expect(find.text('My song.mp3'), findsOneWidget);
    expect(chosen(), '__upload__');

    await tester.tap(find.text('Aurora'));
    await tester.pumpAndSettle();
    expect(chosen(), 'content://media/1');
    expect(find.text('My song.mp3'), findsNothing);

    await tester.tap(find.text('Upload your own sound'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default alarm sound'));
    await tester.pumpAndSettle();
    expect(chosen(), '__default__');
    expect(radio('__default__'), isNotNull);
  });

  testWidgets('saving returns an alarm carrying vibration and the sound', (
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
                  builder: (_) => AlarmEditor(engine: _PickerEngine()),
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

    final row = find.widgetWithText(ListTile, 'Sound');
    await reveal(tester, row, 250);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aurora'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Vibration'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('Aurora · Vibration off'), findsOneWidget);

    await reveal(tester, find.text('Save alarm'), 250);
    await tester.tap(find.text('Save alarm'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.vibrate, isFalse);
    expect(saved!.customSoundName, 'Aurora');
  });
  testWidgets(
    'get-out-of-bed preset selects an object and QR, no snooze, one check-in',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AlarmEditor())),
      );
      await tester.tap(find.widgetWithText(ListTile, 'Get out of bed'));
      await tester.pumpAndSettle();
      // Leaving the room is done by an object or a scan, so QR is checked too.
      // The QR card sits above the wake-up object section, so find it first.
      await reveal(
        tester,
        find.widgetWithText(TextField, 'QR code value'),
        250,
      );
      expect(find.widgetWithText(TextField, 'QR code value'), findsOneWidget);
      final qr = tester.widget<TextField>(
        find.widgetWithText(TextField, 'QR code value'),
      );
      // Choosing the preset must also give the QR challenge a code to scan.
      expect(qr.controller!.text.trim(), isNotEmpty);
      await reveal(tester, find.text('Your wake-up object'), 250);
      await reveal(tester, find.widgetWithText(ChoicePill, 'No snooze'), 250);
      expect(
        tester
            .widget<ChoicePill>(find.widgetWithText(ChoicePill, 'No snooze'))
            .selected,
        isTrue,
      );
      await reveal(tester, find.text('Stay Awake check-in'), 250);
      await reveal(tester, find.widgetWithText(ChoicePill, 'Off'), 150);
      // Only the check-in five-minute choice is selected.
      expect(
        tester
            .widgetList<ChoicePill>(find.widgetWithText(ChoicePill, '5 min'))
            .where((c) => c.selected)
            .length,
        1,
      );
    },
  );

  testWidgets('get-out-of-bed preset can practise with its generated QR', (
    tester,
  ) async {
    final engine = _PracticeEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AlarmEditor(engine: engine)),
      ),
    );
    await tester.tap(find.widgetWithText(ListTile, 'Get out of bed'));
    await tester.pumpAndSettle();
    final button = find.text('Practice this challenge — no alarm scheduled');
    await reveal(tester, button, 250);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(engine.practiced, isNotNull);
    expect(engine.practiced!.escapes, {EscapeKind.object, EscapeKind.qr});
    expect(engine.practiced!.qrValue.trim(), isNotEmpty);
    expect(find.textContaining('needs a code'), findsNothing);
  });

  testWidgets('practice uses the chosen draft without scheduling an alarm', (
    tester,
  ) async {
    final engine = _PracticeEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AlarmEditor(engine: engine)),
      ),
    );
    await tester.tap(find.widgetWithText(ListTile, 'Simple'));
    await tester.pumpAndSettle();
    final button = find.text('Practice this challenge — no alarm scheduled');
    await reveal(tester, button, 250);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
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

class _PickerEngine extends EngineUnavailable implements CustomSoundEngine {
  @override
  bool get supportsCustomSounds => true;

  @override
  Future<List<PickedSound>> listSystemSounds() async => const [
    PickedSound(id: 'content://media/1', name: 'Aurora'),
    PickedSound(id: 'content://media/2', name: 'Nebula'),
  ];

  @override
  Future<PickedSound> importSystemSound(String uri) async =>
      PickedSound(id: uri, name: 'Aurora');

  @override
  Future<PickedSound?> pickCustomSound() async =>
      const PickedSound(id: 'mine.mp3', name: 'My song.mp3');

  @override
  Future<void> previewCustomSound(String id, {bool vibrate = false}) async {}

  @override
  Future<void> stopAudibilitySample() async {}
}
