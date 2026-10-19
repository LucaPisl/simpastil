import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/secure_storage_options.dart';

void main() {
  group('Android secure storage options', () {
    test('keep stored secrets readable and never erase them on error', () {
      final map = simpastilAndroidStorageOptions.toMap();

      // A failed read must not delete the database key or credentials.
      expect(map['resetOnError'], 'false');
      // Moves flutter_secure_storage 9 values out of
      // EncryptedSharedPreferences, which version 11 cannot read.
      expect(map['migrateOnAlgorithmChange'], 'true');
      // The backup path skips that move while the algorithms are unchanged.
      expect(map['migrateWithBackup'], 'false');
      expect(
        map['keyCipherAlgorithm'],
        'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
      );
      expect(map['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
    });

    test('keep the default storage file, key prefix and key aliases', () {
      final map = simpastilAndroidStorageOptions.toMap();

      // A different name, prefix or namespace points at an empty store.
      expect(map['sharedPreferencesName'], isEmpty);
      expect(map['preferencesKeyPrefix'], isEmpty);
      expect(map['storageNamespace'], isEmpty);
      expect(map['enforceBiometrics'], 'false');
    });

    test('are not the library defaults for erasing on error', () {
      expect(const AndroidOptions().toMap()['resetOnError'], 'true');
      expect(simpastilAndroidStorageOptions.toMap()['resetOnError'], 'false');
    });
  });

  test('iOS values stay on this device and readable after first unlock', () {
    expect(
      simpastilIosStorageOptions.toMap()['accessibility'],
      KeychainAccessibility.first_unlock_this_device.name,
    );
  });

  test('every secret store goes through the shared instance', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('secure_storage_options.dart')) continue;
      final source = entity.readAsStringSync();
      if (RegExp(r'FlutterSecureStorage\s*\(').hasMatch(source) ||
          source.contains('AndroidOptions(') ||
          source.contains('IOSOptions(')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
