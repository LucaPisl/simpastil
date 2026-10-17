import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'protected_database.dart';

/// Current protected files are care generations and immutable recovery copies.
/// Portable exports have a separate password boundary; drafts stay in care.db.
class ProtectedFileStore {
  const ProtectedFileStore({
    required this.root,
    required this.keyStore,
    required this.maximumSchema,
  });
  final Directory root;
  final DeviceDatabaseKeyStore keyStore;
  final int maximumSchema;

  Future<ProtectedStoreManifest> manifest() async {
    final value = await readProtectedStoreManifest(root, maximumSchema);
    if (value == null || value['active'] == null) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.activeStoreMissing,
      );
    }
    return ProtectedStoreManifest(value);
  }

  File file(String generation, String name) =>
      protectedStoreFile(root, generation, name);

  Future<String> generationPurpose(String generation) async {
    final descriptor = file(generation, 'generation.json');
    if (await descriptor.resolveSymbolicLinks() !=
            '${await root.resolveSymbolicLinks()}/$generation/generation.json' ||
        await descriptor.length() > 2048) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.invalidMarker,
      );
    }
    final value = jsonDecode(await descriptor.readAsString());
    if (value is! Map ||
        value['version'] != 1 ||
        value['generation'] != generation ||
        value['everPublished'] != true ||
        !const {
          'startupPreparation',
          'fullRestoreRecovery',
        }.contains(value['purpose'])) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.invalidMarker,
      );
    }
    return value['purpose'] as String;
  }

  Future<DatabaseEvidence> verify(String generation, String name) async {
    final target = file(generation, name);
    try {
      final privateRoot = await root.resolveSymbolicLinks();
      if (await target.resolveSymbolicLinks() !=
          '$privateRoot/$generation/$name') {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.unreadableStore,
        );
      }
    } on ProtectedStoreFailure {
      rethrow;
    } catch (_) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.unreadableStore,
      );
    }
    return verifyProtectedDatabase(target, keyStore, maximumSchema);
  }
}

class ProtectedStoreManifest {
  ProtectedStoreManifest(Map<String, dynamic> value)
    : value = Map.unmodifiable(value),
      revision = sha256.convert(utf8.encode(jsonEncode(value))).toString();
  final Map<String, dynamic> value;
  final String revision;
  String get active => value['active'] as String;
  String? get recovery => value['recovery'] as String?;
  String? get pending => value['pending'] as String?;
  String? get originalRecovery =>
      (value['retirement'] as Map?)?['generation'] as String?;
  Set<String> get retained => {
    active,
    if (recovery != null) recovery!,
    if (pending != null) pending!,
    if (originalRecovery != null) originalRecovery!,
  };
}
