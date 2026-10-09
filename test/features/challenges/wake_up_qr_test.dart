import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/features/challenges/wake_up_qr.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('shared QR survives new repository instances and competing creation', () async {
    final values = await Future.wait([
      WakeUpQrRepository().getOrCreate(),
      WakeUpQrRepository().getOrCreate(),
      WakeUpQrRepository().getOrCreate(),
    ]);
    expect(values.toSet(), hasLength(1));
    expect(values.first, matches(RegExp(r'^[A-HJ-NP-Z2-9]{16}-[0-9]{4}$')));
    expect(await WakeUpQrRepository().getOrCreate(), values.first);
  });

  test('adopts an existing printed code only before a shared code exists', () async {
    final first = await WakeUpQrRepository().getOrCreate(preferredValue: ' PRINTED-CODE ');
    expect(first, 'PRINTED-CODE');
    expect(await WakeUpQrRepository().getOrCreate(preferredValue: 'OTHER-CODE'), first);
  });
}
