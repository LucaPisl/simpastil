import 'dart:io';

import 'package:drift/isolate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simpastil_storage/simpastil_storage.dart';

import '../db/database.dart';
import '../backup/restore_preferences.dart';
import '../storage/portable_preference_writer.dart';
import '../storage/shared_preferences_provider.dart';
import '../storage/device_database_key_store.dart';
import '../storage/protected_database.dart';
import '../storage/protected_file_store.dart';
import '../storage/recovery_copy_service.dart';
import '../storage/safe_cleanup_service.dart';
import '../storage/storage_health.dart';
import '../storage/storage_inventory_service.dart';

class ProtectionReadiness {
  const ProtectionReadiness.ready({
    this.preferenceRestore = PreferenceRestoreState.none,
  }) : failure = null;
  const ProtectionReadiness.unavailable(this.failure)
    : preferenceRestore = PreferenceRestoreState.none;
  final ProtectedStoreFailureCode? failure;
  final PreferenceRestoreState preferenceRestore;
  bool get ready => failure == null;
}

final restorePreferencesServiceProvider = Provider<RestorePreferencesService>(
  (ref) => RestorePreferencesService(
    database: ref.watch(databaseProvider),
    preferences: ref.watch(sharedPreferencesProvider),
    effectsGate: ref.watch(portablePreferenceGateProvider),
  ),
);

final protectionReadinessProvider = FutureProvider<ProtectionReadiness>((
  ref,
) async {
  ref.watch(careReopenedProvider);
  try {
    await ref.watch(databaseProvider).customSelect('SELECT 1').get();
    // A committed care replacement remains available even when its separate
    // preference intent needs retry or renewed review. Resolve it before the
    // foreground builds preference caches and starts optional projections.
    var preferences = PreferenceRestoreState.pending;
    try {
      preferences = await ref
          .read(restorePreferencesServiceProvider)
          .reconcile();
    } catch (_) {
      // The durable intent remains intact for retry; this is not lost care.
    }
    return ProtectionReadiness.ready(preferenceRestore: preferences);
  } catch (error) {
    final cause = error is DriftRemoteException ? error.remoteCause : error;
    return ProtectionReadiness.unavailable(
      cause is ProtectedStoreFailure
          ? cause.code
          : ProtectedStoreFailureCode.ioFailure,
    );
  }
});

class LocalStorageServices {
  const LocalStorageServices(this.files, this.legacy);
  final ProtectedFileStore files;
  final File legacy;
  StorageHealthService get health => StorageHealthService(files, legacy);
  RecoveryCopyService get recovery => RecoveryCopyService(files);
  StorageInventoryService get inventory => StorageInventoryService(
    files,
    legacy,
    availableBytes: const SimpastilStorage().availableBytes,
  );
  SafeCleanupService get cleanup => SafeCleanupService(
    files,
    syncDirectory: const SimpastilStorage().syncDirectory,
  );
}

final localStorageServicesProvider = FutureProvider<LocalStorageServices>((
  ref,
) async {
  final readiness = await ref.watch(protectionReadinessProvider.future);
  if (!readiness.ready) throw ProtectedStoreFailure(readiness.failure!);
  const native = SimpastilStorage();
  final documents = await getApplicationDocumentsDirectory();
  return LocalStorageServices(
    ProtectedFileStore(
      root: Directory('${await native.noBackupPath()}/care'),
      keyStore: const SecureDeviceDatabaseKeyStore(),
      maximumSchema: AppDatabase.supportedSchemaVersion,
    ),
    File('${documents.path}/simpastil.db'),
  );
});
