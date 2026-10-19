import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakeguard/features/alarms/analog_clock.dart';

void main() {
  testWidgets('shows the current time and keeps running', (tester) async {
    var now = DateTime(2026, 10, 19, 22, 30, 15);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AnalogClock(now: () => now)),
      ),
    );
    expect(find.bySemanticsLabel('Current time 10:30 PM'), findsOneWidget);

    // A minute later the clock has moved on by itself.
    now = DateTime(2026, 10, 19, 22, 31, 16);
    await tester.pump(const Duration(seconds: 2));
    expect(find.bySemanticsLabel('Current time 10:31 PM'), findsOneWidget);
  });

  testWidgets('stops its timer when removed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AnalogClock(now: () => DateTime(2026, 1, 1, 6))),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    // A leaked timer would fail the test at teardown.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('fits a narrow screen and never exceeds its max size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalogClock(now: () => DateTime(2026, 1, 1, 10, 10, 30)),
        ),
      ),
    );
    final size = tester.getSize(find.byType(CustomPaint).last);
    expect(size.width, lessThanOrEqualTo(300));
    expect(size.width, closeTo(320 * 0.72, 0.5));
    expect(tester.takeException(), isNull);
  });
}
