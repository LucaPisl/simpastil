import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> arb(String name) =>
      jsonDecode(File('lib/l10n/$name.arb').readAsStringSync())
          as Map<String, dynamic>;

  test('the false connected-details sentence is gone from both languages', () {
    expect(arb('app_en').containsKey('t09_connectedDetails'), isFalse);
    expect(arb('app_ro').containsKey('t09_connectedDetails'), isFalse);
  });

  test('English copy says medication, never medicine', () {
    final en = arb('app_en');
    final bad = [
      for (final e in en.entries)
        if (!e.key.startsWith('@') &&
            e.value is String &&
            RegExp(
              r'\bmedicines?\b',
              caseSensitive: false,
            ).hasMatch(e.value as String))
          e.key,
    ];
    expect(bad, isEmpty);
  });
}
