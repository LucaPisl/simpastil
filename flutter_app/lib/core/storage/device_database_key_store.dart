import 'protected_database.dart';
import 'secure_storage_options.dart';

/// Independent of session credentials and the optional interface lock.
/// Token sign-out never deletes this key. No delete/reset API is exposed.
class SecureDeviceDatabaseKeyStore implements DeviceDatabaseKeyStore {
  const SecureDeviceDatabaseKeyStore();

  static const _name = 'simpastil_protected_care_key_v1';
  static const _storage = simpastilSecureStorage;

  @override
  Future<String?> read() => _storage.read(key: _name);

  @override
  Future<void> write(String key) => _storage.write(key: _name, value: key);
}
