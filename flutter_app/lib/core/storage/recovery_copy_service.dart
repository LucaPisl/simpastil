import 'protected_database.dart';
import 'protected_file_store.dart';

enum RecoveryCopyState { absent, checked, unavailable }

class RecoveryCopyCheck {
  const RecoveryCopyCheck(
    this.state, {
    this.bytes,
    this.savedAt,
    this.checkedAt,
    this.evidence,
  });
  final RecoveryCopyState state;
  final int? bytes;
  final DateTime? savedAt;
  final DateTime? checkedAt;
  final DatabaseEvidence? evidence;
}

class RecoveryCopyService {
  const RecoveryCopyService(this.store);
  final ProtectedFileStore store;
  Future<RecoveryCopyCheck> check(
    ProtectedStoreManifest manifest, {
    bool original = false,
  }) async {
    final generation = original ? manifest.originalRecovery : manifest.recovery;
    if (generation == null) {
      return const RecoveryCopyCheck(RecoveryCopyState.absent);
    }
    try {
      final evidence = await store.verify(generation, 'recovery.db');
      final expected =
          (original
                  ? manifest.value['retirement']
                  : manifest.value['recoveryEvidence'])
              as Map?;
      if (expected == null ||
          expected['schema'] is! int ||
          expected['fingerprint'] is! String ||
          evidence.schema != expected['schema'] ||
          evidence.fingerprint != expected['fingerprint']) {
        return const RecoveryCopyCheck(RecoveryCopyState.unavailable);
      }
      var bytes = await store.file(generation, 'recovery.db').length();
      final preferencesDigest = expected['preferencesDigest'];
      if (await store.generationPurpose(generation) == 'fullRestoreRecovery' &&
          (preferencesDigest is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(preferencesDigest))) {
        return const RecoveryCopyCheck(RecoveryCopyState.unavailable);
      }
      if (preferencesDigest != null) {
        if (preferencesDigest is! String) {
          return const RecoveryCopyCheck(RecoveryCopyState.unavailable);
        }
        await readProtectedRecoveryPreferences(
          root: store.root,
          keyStore: store.keyStore,
          generation: generation,
          expectedDigest: preferencesDigest,
        );
        bytes += await store.file(generation, 'preferences.db').length();
      }
      final saved = expected['savedAtMs'];
      return RecoveryCopyCheck(
        RecoveryCopyState.checked,
        bytes: bytes,
        savedAt: saved is int
            ? DateTime.fromMillisecondsSinceEpoch(saved, isUtc: true)
            : null,
        checkedAt: DateTime.now().toUtc(),
        evidence: evidence,
      );
    } catch (_) {
      return const RecoveryCopyCheck(RecoveryCopyState.unavailable);
    }
  }
}
