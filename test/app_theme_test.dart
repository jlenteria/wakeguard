import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakeguard/app.dart';

void main() {
  test('light mode is white on every surface users notice', () {
    final theme = WakeGuardApp.themeFor(Brightness.light);
    expect(theme.scaffoldBackgroundColor, Colors.white);
    expect(theme.bottomSheetTheme.modalBackgroundColor, Colors.white);
    expect(theme.appBarTheme.backgroundColor, Colors.white);
    expect(theme.navigationBarTheme.backgroundColor, Colors.white);
  });

  test('dark mode keeps the sheet dark but lifts the cards above it', () {
    final theme = WakeGuardApp.themeFor(Brightness.dark);
    final sheet = theme.bottomSheetTheme.modalBackgroundColor!;
    final card = theme.cardTheme.color!;

    // Both dark, so text stays readable on each.
    expect(sheet.computeLuminance(), lessThan(0.2));
    expect(card.computeLuminance(), lessThan(0.2));
    // The card is lighter than the sheet, so it does not blend into it.
    expect(card.computeLuminance(), greaterThan(sheet.computeLuminance()));
  });
}
