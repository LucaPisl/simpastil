import 'protected_database.dart';
import 'protected_file_store.dart';
import 'recovery_copy_service.dart';
import 'dart:io';

class StorageHealth {
  const StorageHealth({
    required this.activeReadable,
    required this.recovery,
    required this.legacyRetirement,
    this.failure,
  });
  final bool activeReadable;
  final RecoveryCopyCheck recovery;
  final LegacyRetirementStatus legacyRetirement;
  final ProtectedStoreFailureCode? failure;
  // This reports only verified care/recovery protection. Inventory separately
  // identifies unfinished copies; an optional UI lock is not encryption.
}

class StorageHealthService {
  const StorageHealthService(this.store, this.legacy);
  final ProtectedFileStore store;
  final File legacy;
  Future<StorageHealth> check() async {
    try {
      final manifest = await store.manifest();
      final active = await store.verify(manifest.active, 'care.db');
      if (active.schema != store.maximumSchema) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.unsupportedSchema,
        );
      }
      final recovery = await RecoveryCopyService(store).check(manifest);
      final retired =
          (manifest.value['retirement'] as Map?)?['state'] == 'retired';
      final originalExists = await legacy.exists();
      var remnantsExist = originalExists;
      for (final suffix in ['-wal', '-shm', '-journal']) {
        remnantsExist =
            remnantsExist || await File('${legacy.path}$suffix').exists();
      }
      final description = manifest.value['retirement'];
      return StorageHealth(
        activeReadable: true,
        recovery: recovery,
        legacyRetirement: remnantsExist || (description != null && !retired)
            ? LegacyRetirementStatus.pending
            : retired
            ? LegacyRetirementStatus.retired
            : LegacyRetirementStatus.notNeeded,
      );
    } on ProtectedStoreFailure catch (failure) {
      return StorageHealth(
        activeReadable: false,
        recovery: const RecoveryCopyCheck(RecoveryCopyState.unavailable),
        legacyRetirement: LegacyRetirementStatus.pending,
        failure: failure.code,
      );
    } catch (_) {
      return const StorageHealth(
        activeReadable: false,
        recovery: RecoveryCopyCheck(RecoveryCopyState.unavailable),
        legacyRetirement: LegacyRetirementStatus.pending,
        failure: ProtectedStoreFailureCode.ioFailure,
      );
    }
  }
}
