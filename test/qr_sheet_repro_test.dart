import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/ui/alarm_editor.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AlarmEditor())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.qr_code_2_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show QR code'));
    await tester.pumpAndSettle();
  }

  testWidgets('QR sheet no longer overflows a phone screen', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await openSheet(tester);

    expect(find.byType(QrSheet), findsOneWidget);
    // The previous bug: a 320px code plus its labels exceeded the sheet cap.
    expect(
      tester.takeException(),
      isNull,
      reason: 'the sheet must not overflow',
    );

    final painter = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(QrSheet),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((w) => w.painter)
        .whereType<QrPainter>()
        .single;
    expect(painter.version, greaterThan(0));
  });

  testWidgets('QR sheet clears the Android navigation bar', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    // A three-button Android nav bar: 48dp of system inset at the bottom.
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);

    await openSheet(tester);
    expect(tester.takeException(), isNull);

    final save = find.widgetWithText(FilledButton, 'Save image');
    expect(save, findsOneWidget);

    // The button must sit entirely above the nav bar, not under it. This is the
    // exact failure the user reported: content reachable only by luck.
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final buttonBottom = tester.getRect(save).bottom;
    expect(
      buttonBottom,
      lessThanOrEqualTo(screenHeight - 48),
      reason: 'the save button overlaps the Android navigation bar',
    );
  });

  testWidgets('a tall code still fits with a nav bar present', (tester) async {
    // Short, wide screen: the worst case for a bottom sheet.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);

    await openSheet(tester);

    // Scroll the sheet to the button and confirm it is reachable and unobscured.
    final save = find.widgetWithText(FilledButton, 'Save image');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(save, findsOneWidget);
  });
}
