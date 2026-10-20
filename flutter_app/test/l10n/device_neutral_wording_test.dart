import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app runs on phones and tablets, so the sync and recovery wording speaks
/// of "this device", never of one form factor.
void main() {
  const neutralPrefixes = [
    'recovery_',
    'history_',
    'sync_',
    'review_',
    'thread_',
  ];
  const phoneWords = {'en': 'phone', 'ro': 'telefon'};
  // Settings that really are about the phone's own features.
  const allowed = {'settings_reduceMotionByPhone', 'settings_deviceNameHint'};

  for (final lang in phoneWords.keys) {
    test('sync and recovery wording is device-neutral in $lang', () {
      final arb =
          jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
              as Map<String, dynamic>;
      final offenders = [
        for (final entry in arb.entries)
          if (!entry.key.startsWith('@') &&
              entry.value is String &&
              neutralPrefixes.any(entry.key.startsWith) &&
              !allowed.contains(entry.key) &&
              (entry.value as String).toLowerCase().contains(phoneWords[lang]!))
            entry.key,
      ];
      expect(offenders, isEmpty);
    });
  }
}
