import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/protected_database.dart';
import 'package:simpastil/core/storage/protected_file_store.dart';
import 'package:simpastil/core/storage/protected_store_gate.dart';
import 'package:simpastil/core/storage/recovery_copy_service.dart';
import 'package:simpastil/core/storage/safe_cleanup_service.dart';
import 'package:sqlite3/sqlite3.dart';

class _Keys implements DeviceDatabaseKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String key) async => value = key;
}

void main() {
  late Directory scratch, root;
  late _Keys keys;
  late PreparedDatabase ready;
  late ProtectedFileStore store;
  Future<void> sync(String _) async {}
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp(
      'simpastil-restore-recovery-',
    );
    root = Directory('${scratch.path}/private');
    keys = _Keys();
    final legacy = File('${scratch.path}/legacy.db');
    final seed = sqlite3.open(legacy.path);
    seed.execute('CREATE TABLE care (id TEXT PRIMARY KEY, state TEXT)');
    seed.execute(
      "INSERT INTO care VALUES ('fictional-original', 'retained-draft-and-queue')",
    );
    seed.userVersion = 5;
    seed.close();
    ready = await ProtectedStoreCoordinator(
      root: root,
      legacy: legacy,
      keyStore: keys,
      expectedSchema: 5,
      syncDirectory: sync,
      migrateCandidate: (_) async {},
    ).prepare();
    store = ProtectedFileStore(root: root, keyStore: keys, maximumSchema: 5);
  });
  tearDown(() async => scratch.delete(recursive: true));

  test(
    'replacement copy reopens exact committed WAL care and protected preferences without switching active',
    () async {
      final writer = ready.openEstablished();
      addTearDown(writer.close);
      writer.execute('PRAGMA journal_mode=WAL');
      writer.execute('PRAGMA wal_autocheckpoint=0');
      writer.execute(
        "INSERT INTO care VALUES ('fictional-wal-original', 'unshared-original')",
      );
      writer.execute('BEGIN IMMEDIATE');
      writer.execute('UPDATE care SET state=state');
      final before = await store.manifest();
      final prefs = <String, Object?>{
        'app_locale': 'ro',
        'notification_privacy_mode': true,
      };
      final recovery = await withProtectedStoreGate(
        root,
        () => createProtectedReplacementRecovery(
          root: root,
          keyStore: keys,
          maximumSchema: 5,
          expectedManifestRevision: before.revision,
          preferences: prefs,
          syncDirectory: sync,
        ),
      );
      expect((await store.manifest()).active, before.active);
      expect((await store.manifest()).recovery, recovery.generation);
      expect(
        (await RecoveryCopyService(store).check(await store.manifest())).state,
        RecoveryCopyState.checked,
      );
      expect(recovery.evidence.rows['care'], 2);
      expect(
        await readProtectedRecoveryPreferences(
          root: root,
          keyStore: keys,
          generation: recovery.generation,
          expectedDigest: recovery.preferencesDigest,
        ),
        prefs,
      );
      for (final name in ['recovery.db', 'preferences.db']) {
        final bytes = await File(
          '${root.path}/${recovery.generation}/$name',
        ).readAsBytes();
        expect(latin1.decode(bytes).contains('SQLite format 3'), isFalse);
        expect(
          latin1.decode(bytes).contains('retained-draft-and-queue'),
          isFalse,
        );
        expect(latin1.decode(bytes).contains('app_locale'), isFalse);
      }
      writer.execute("DELETE FROM care WHERE id='fictional-original'");
      writer.execute('ROLLBACK');
      expect(writer.select('SELECT * FROM care'), hasLength(2));
      final cleanup = await SafeCleanupService(
        store,
        syncDirectory: sync,
      ).plan();
      expect(cleanup.generations, isNot(contains(recovery.generation)));
      final markerFile = File('${root.path}/store.json');
      final originalMarker = await markerFile.readAsString();
      final missingDescriptor =
          jsonDecode(originalMarker) as Map<String, dynamic>;
      (missingDescriptor['recoveryEvidence'] as Map).remove(
        'preferencesDigest',
      );
      await markerFile.writeAsString(
        jsonEncode(missingDescriptor),
        flush: true,
      );
      expect(
        (await RecoveryCopyService(store).check(await store.manifest())).state,
        RecoveryCopyState.unavailable,
      );
      await markerFile.writeAsString(originalMarker, flush: true);
      // A checked replacement copy includes its preference recovery too.
      await File(
        '${root.path}/${recovery.generation}/preferences.db',
      ).writeAsBytes([1, 2, 3], flush: true);
      expect(
        (await RecoveryCopyService(store).check(await store.manifest())).state,
        RecoveryCopyState.unavailable,
      );
      expect(writer.select('SELECT * FROM care'), hasLength(2));
    },
  );

  test(
    'failed recovery verification leaves original care and prior checked recovery intact',
    () async {
      final writer = ready.openEstablished();
      addTearDown(writer.close);
      writer.execute('BEGIN IMMEDIATE');
      final before = await store.manifest();
      await expectLater(
        withProtectedStoreGate(
          root,
          () => createProtectedReplacementRecovery(
            root: root,
            keyStore: keys,
            maximumSchema: 5,
            expectedManifestRevision: before.revision,
            preferences: const {'app_locale': 'ro'},
            syncDirectory: sync,
            onPoint: (point) async {
              if (point == PreparationPoint.recoveryEncrypted) {
                throw StateError('controlled failure');
              }
            },
          ),
        ),
        throwsA(isA<ProtectedStoreFailure>()),
      );
      writer.execute('ROLLBACK');
      expect((await store.manifest()).revision, before.revision);
      expect(writer.select('SELECT * FROM care'), hasLength(1));
      expect(
        (await RecoveryCopyService(store).check(before)).state,
        RecoveryCopyState.checked,
      );
    },
  );
}
