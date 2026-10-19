import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one set of options every [FlutterSecureStorage] in the app uses.
///
/// The database key, the sign-in credentials and the pinned server keys all
/// live in the same Android storage file, so the instances must agree on how
/// it is encrypted and migrated. Changing any value here can make stored
/// secrets unreadable; `secure_storage_options_test.dart` pins them.
const simpastilAndroidStorageOptions = AndroidOptions(
  // Never erase stored values because one read or write failed. The library
  // default (true) deletes the key, or the whole file, and retries; losing the
  // database key would make the encrypted database unreadable for good.
  resetOnError: false,
  // Moves values written by flutter_secure_storage 9 (Jetpack
  // EncryptedSharedPreferences) into the custom-cipher store on first access.
  // Version 11 can no longer read them, so this must stay on until every
  // supported install has passed through a build that ran the migration.
  migrateOnAlgorithmChange: true,
  // Its backup-protected path only migrates values when the algorithms
  // change, so with unchanged algorithms it would skip the one-time move from
  // EncryptedSharedPreferences and leave the old values unread.
  migrateWithBackup: false,
  // Spelled out so a change of the library defaults cannot re-encrypt data.
  keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
  storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
);

/// First unlock keeps values readable after a reboot (for background work)
/// and keeps them out of backups and device transfers.
const simpastilIosStorageOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

/// Shared by [SecureDeviceDatabaseKeyStore], [TokenService] and
/// [SecureCredentialSlotStore].
const simpastilSecureStorage = FlutterSecureStorage(
  aOptions: simpastilAndroidStorageOptions,
  iOptions: simpastilIosStorageOptions,
);
