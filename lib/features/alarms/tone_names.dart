/// Anything outside ASCII and the Latin letter blocks (Chinese, Arabic, ...).
final _nonLatin = RegExp(r'[^\u0000-\u007F\u00C0-\u024F]');

/// Device tones are often titled "local name;English name". Returns the
/// English part only, or null when the title has no English text at all.
String? englishToneName(String raw) {
  final parts = raw
      .split(RegExp(r'[;\uFF1B]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  for (final part in parts.reversed) {
    if (!_nonLatin.hasMatch(part)) return part;
  }
  // No clean English segment: keep whatever Latin text is mixed into the title.
  final stripped = raw
      .replaceAll(_nonLatin, ' ')
      .replaceAll(RegExp(r'[;\uFF1B]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return RegExp(r'[A-Za-z]').hasMatch(stripped) ? stripped : null;
}
