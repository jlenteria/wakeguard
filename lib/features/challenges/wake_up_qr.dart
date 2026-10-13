import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stable device-local QR value; alarms snapshot it so printed codes stay valid.
class WakeUpQrRepository {
  static const _key = 'wakeguard.wakeUpQr.v1';
  static Future<void> _operations = Future<void>.value();
  static String? _cached;

  /// Clears the in-process cache; tests reset the shared-preferences backend
  /// between cases, so a stale value must not bleed across them.
  @visibleForTesting
  static void resetCache() => _cached = null;

  /// The value from memory when warm, or null before the first read. The editor
  /// flow checks this so tapping an alarm never blocks on disk I/O.
  static String? get cached {
    final value = _cached;
    return (value != null && value.isNotEmpty) ? value : null;
  }

  Future<String> getOrCreate({String? preferredValue}) {
    final warm = cached;
    if (warm != null) return Future.value(warm);
    final result = _operations.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key)?.trim();
      if (saved != null && saved.isNotEmpty) {
        _cached = saved;
        return saved;
      }
      final preferred = preferredValue?.trim() ?? '';
      final value = preferred.isNotEmpty ? preferred : generateQrSecret();
      if (!await prefs.setString(_key, value)) {
        throw StateError('Could not save the wake-up QR code');
      }
      _cached = value;
      return value;
    });
    _operations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

String generateQrSecret() {
  final random = Random.secure();
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final letters = List.generate(
    16,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
  final digits = List.generate(4, (_) => random.nextInt(10)).join();
  return '$letters-$digits';
}
