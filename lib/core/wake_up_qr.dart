import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// One stable, device-local QR destination. Alarms store a snapshot of its value
/// so existing custom/printed codes remain valid and native delivery stays offline.
class WakeUpQrRepository {
  static const _key = 'wakeguard.wakeUpQr.v1';
  static Future<void> _operations = Future<void>.value();

  Future<String> getOrCreate({String? preferredValue}) {
    final result = _operations.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key)?.trim();
      if (saved != null && saved.isNotEmpty) return saved;
      final preferred = preferredValue?.trim() ?? '';
      final value = preferred.isNotEmpty ? preferred : generateQrSecret();
      if (!await prefs.setString(_key, value)) {
        throw StateError('Could not save the wake-up QR code');
      }
      return value;
    });
    _operations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

String generateQrSecret() {
  final random = Random.secure();
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final letters = List.generate(16, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  final digits = List.generate(4, (_) => random.nextInt(10)).join();
  return '$letters-$digits';
}
