import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'protected_database.dart';

/// Independent of session credentials and the optional interface lock.
/// Token sign-out never deletes this key. No delete/reset API is exposed.
class SecureDeviceDatabaseKeyStore implements DeviceDatabaseKeyStore {
  const SecureDeviceDatabaseKeyStore();

  static const _name = 'simpastil_protected_care_key_v1';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      keyCipherAlgorithm:
          KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read() => _storage.read(key: _name);

  @override
  Future<void> write(String key) => _storage.write(key: _name, value: key);
}
