import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('offline motivational library contains 100 distinct, brief quotes', () {
    final quotes =
        (jsonDecode(
                  File('resources/motivational_quotes.json').readAsStringSync(),
                )
                as List)
            .cast<String>();
    expect(quotes, hasLength(100));
    expect(quotes.toSet(), hasLength(100));
    for (final quote in quotes) {
      expect(quote, isNotEmpty);
      expect(quote.trim(), quote);
      expect(quote.length, lessThanOrEqualTo(90));
    }
  });
}
