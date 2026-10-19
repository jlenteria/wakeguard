import 'package:flutter_test/flutter_test.dart';
import 'package:wakeguard/features/alarms/alarms_screen.dart';

void main() {
  final alarm = DateTime(2026, 10, 19, 16, 5);

  test('is not "now" while the clock still shows an earlier minute', () {
    expect(ringsIn(alarm, DateTime(2026, 10, 19, 16, 4, 1)), 'in 1m');
    expect(ringsIn(alarm, DateTime(2026, 10, 19, 16, 4, 59)), 'in 1m');
  });

  test('is "now" from the alarm minute onward', () {
    expect(ringsIn(alarm, DateTime(2026, 10, 19, 16, 5)), 'now');
    expect(ringsIn(alarm, DateTime(2026, 10, 19, 16, 5, 30)), 'now');
    expect(ringsIn(alarm, DateTime(2026, 10, 19, 17, 0)), 'now');
  });

  test('counts minutes, hours and days by clock minute', () {
    expect(ringsIn(alarm, DateTime(2026, 10, 19, 15, 50, 40)), 'in 15m');
    expect(ringsIn(alarm, DateTime(2026, 10, 19, 14, 0)), 'in 2h 5m');
    expect(ringsIn(alarm, DateTime(2026, 10, 18, 12, 0)), 'in 1d 4h');
  });
}
