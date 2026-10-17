import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/protected_database.dart';
import 'package:simpastil/core/storage/protected_file_store.dart';
import 'package:simpastil/core/storage/recovery_copy_service.dart';
import 'package:simpastil/core/storage/safe_cleanup_service.dart';
import 'package:simpastil/core/storage/storage_inventory_service.dart';
import 'package:simpastil/core/storage/storage_health.dart';
import 'package:sqlite3/sqlite3.dart';

class _Keys implements DeviceDatabaseKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String key) async => value = key;
}

class _Interrupted implements Exception {}

void main() {
  late Directory scratch;
  late Directory root;
  late File legacy;
  late _Keys keys;
  late ProtectedFileStore store;
  late PreparedDatabase ready;
  late String abandoned;
  Future<void> sync(String _) async {}
  ProtectedStoreCoordinator coordinator({bool interrupted = false}) =>
      ProtectedStoreCoordinator(
        root: root,
        legacy: legacy,
        keyStore: keys,
        expectedSchema: 5,
        syncDirectory: sync,
        migrateCandidate: (candidate) async {
          final db = sqlite3.open(candidate.file.path);
          try {
            candidate.configure(db);
            db.userVersion = 5;
          } finally {
            db.close();
          }
        },
        onPoint: interrupted
            ? (point) async {
                if (point == PreparationPoint.recoveryVerified) {
                  throw _Interrupted();
                }
              }
            : null,
      );
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp(
      'simpastil-storage-services-',
    );
    root = Directory('${scratch.path}/private');
    legacy = File('${scratch.path}/legacy.db');
    keys = _Keys();
    store = ProtectedFileStore(root: root, keyStore: keys, maximumSchema: 5);
    final seed = sqlite3.open(legacy.path);
    seed.execute('CREATE TABLE care (id TEXT PRIMARY KEY, state TEXT)');
    seed.execute(
      "INSERT INTO care VALUES ('retained-draft', 'uncertain-queue')",
    );
    seed.userVersion = 3;
    seed.close();
    await expectLater(
      coordinator(interrupted: true).prepare(),
      throwsA(isA<_Interrupted>()),
    );
    abandoned =
        (jsonDecode(await File('${root.path}/store.json').readAsString())
                as Map)['pending']
            as String;
    ready = await coordinator().prepare();
  });
  tearDown(() async => scratch.delete(recursive: true));

  test(
    'recovery Checked requires actual reopening and preserves original schema',
    () async {
      final check = await RecoveryCopyService(
        store,
      ).check(await store.manifest());
      expect(check.state, RecoveryCopyState.checked);
      expect(check.bytes, greaterThan(0));
      expect(check.savedAt, isNotNull);
      expect(check.checkedAt, isNotNull);
      expect(check.evidence?.schema, 3);
      keys.value = null;
      final refused = await RecoveryCopyService(
        store,
      ).check(await store.manifest());
      expect(refused.state, RecoveryCopyState.unavailable);
      expect(refused.checkedAt, isNull);
      expect(refused.bytes, isNull);
    },
  );
  test(
    'inventory records measured sizes and unknown space distinctly',
    () async {
      final measured = await StorageInventoryService(
        store,
        legacy,
        availableBytes: () async => 12345,
      ).scan();
      expect(measured.sizes[StorageCategory.care], greaterThan(0));
      expect(measured.sizes[StorageCategory.recovery], greaterThan(0));
      expect(measured.sizes[StorageCategory.unfinished], greaterThan(0));
      expect(measured.sizes[StorageCategory.legacyPlaintext], 0);
      expect(measured.availableBytes, 12345);
      final unavailable = await StorageInventoryService(
        store,
        legacy,
        availableBytes: () async => throw const FileSystemException(),
        measure: (_) async => throw const FileSystemException(),
      ).scan();
      expect(unavailable.sizes[StorageCategory.care], isNull);
      expect(unavailable.sizes[StorageCategory.recovery], isNull);
      expect(unavailable.availableBytes, isNull);
    },
  );
  test(
    'cleanup removes only never-published abandoned work and preserves care/recovery',
    () async {
      final service = SafeCleanupService(store, syncDirectory: sync);
      final plan = await service.plan();
      expect(plan.generations, [abandoned]);
      final active = await ready.file.readAsBytes();
      final recovery = await ready.recovery!.readAsBytes();
      final result = await service.execute(plan);
      expect(result.state, CleanupState.complete);
      expect(result.removed, 1);
      expect(await Directory('${root.path}/$abandoned').exists(), isFalse);
      expect(await ready.file.readAsBytes(), active);
      expect(await ready.recovery!.readAsBytes(), recovery);
      final db = ready.openEstablished();
      try {
        expect(
          db.select('SELECT state FROM care').single['state'],
          'uncertain-queue',
        );
      } finally {
        db.close();
      }
    },
  );
  test('changed authoritative state makes a cleanup preview stale', () async {
    final service = SafeCleanupService(store, syncDirectory: sync);
    final plan = await service.plan();
    final marker = File('${root.path}/store.json');
    final state = jsonDecode(await marker.readAsString()) as Map;
    state['reviewRevision'] = 2;
    await marker.writeAsString(jsonEncode(state));
    expect((await service.execute(plan)).state, CleanupState.stale);
    expect(await Directory('${root.path}/$abandoned').exists(), isTrue);
  });
  test(
    'cleanup refuses when the sole authoritative recovery cannot be checked',
    () async {
      final service = SafeCleanupService(store, syncDirectory: sync);
      final plan = await service.plan();
      await ready.recovery!.writeAsBytes([1, 2, 3]);
      expect((await service.execute(plan)).state, CleanupState.refused);
      expect(await Directory('${root.path}/$abandoned').exists(), isTrue);
      expect(await ready.file.exists(), isTrue);
    },
  );
  test(
    'partial cleanup resumes without relying on already-deleted generation metadata',
    () async {
      final failing = SafeCleanupService(
        store,
        syncDirectory: sync,
        deleteDirectory: (directory) async {
          await File('${directory.path}/generation.json').delete();
          throw const FileSystemException('fictional failure');
        },
      );
      expect(
        (await failing.execute(await failing.plan())).state,
        CleanupState.failed,
      );
      expect(await File('${root.path}/cleanup.json').exists(), isTrue);
      final retry = SafeCleanupService(store, syncDirectory: sync);
      expect(
        (await retry.execute(await retry.plan())).state,
        CleanupState.complete,
      );
      expect(
        await Directory('${root.path}/discard-$abandoned').exists(),
        isFalse,
      );
      expect(await ready.file.exists(), isTrue);
      expect(await ready.recovery!.exists(), isTrue);
    },
  );
  test('unknown files in unfinished work prevent automatic cleanup', () async {
    await File('${root.path}/$abandoned/protected-draft.bin').writeAsBytes([1]);
    final service = SafeCleanupService(store, syncDirectory: sync);
    expect((await service.plan()).generations, isEmpty);
    expect(
      await File('${root.path}/$abandoned/protected-draft.bin').exists(),
      isTrue,
    );
  });

  test(
    'pending retirement with absent main file and surviving sidecar stays pending',
    () async {
      final marker = File('${root.path}/store.json');
      final value = jsonDecode(await marker.readAsString()) as Map;
      value['retirement']['state'] = 'deleting';
      await marker.writeAsString(jsonEncode(value));
      await File('${legacy.path}-wal').writeAsBytes([1, 2, 3]);
      final health = await StorageHealthService(store, legacy).check();
      expect(health.activeReadable, isTrue);
      expect(health.legacyRetirement, LegacyRetirementStatus.pending);
    },
  );
  test('same cleanup preview can resume a quarantined deletion', () async {
    final interrupted = SafeCleanupService(
      store,
      syncDirectory: sync,
      onPoint: (point) async {
        if (point == CleanupPoint.quarantined) throw _Interrupted();
      },
    );
    final plan = await interrupted.plan();
    expect((await interrupted.execute(plan)).state, CleanupState.failed);
    final retry = SafeCleanupService(store, syncDirectory: sync);
    final result = await retry.execute(plan);
    expect(result.state, CleanupState.complete);
    expect(result.removed, 1);
  });
  test(
    'recovery requires its expected evidence even if the keyed file is readable',
    () async {
      final manifest = await store.manifest();
      final changed = Map<String, dynamic>.from(manifest.value)
        ..remove('recoveryEvidence');
      final check = await RecoveryCopyService(
        store,
      ).check(ProtectedStoreManifest(changed));
      expect(check.state, RecoveryCopyState.unavailable);
      await File('${root.path}/store.json').writeAsString(jsonEncode(changed));
      await expectLater(
        store.manifest(),
        throwsA(
          isA<ProtectedStoreFailure>().having(
            (failure) => failure.code,
            'code',
            ProtectedStoreFailureCode.invalidMarker,
          ),
        ),
      );
    },
  );
  test(
    'interrupted cleanup intent write cannot publish truncated metadata',
    () async {
      final failing = SafeCleanupService(
        store,
        syncDirectory: sync,
        stageIntent: (file, value) async {
          await file.writeAsString('{', flush: true);
          throw const FileSystemException('fictional interrupted write');
        },
      );
      final plan = await failing.plan();
      expect((await failing.execute(plan)).state, CleanupState.failed);
      expect(await File('${root.path}/cleanup.json').exists(), isFalse);
      expect(await Directory('${root.path}/$abandoned').exists(), isTrue);
      final retry = SafeCleanupService(store, syncDirectory: sync);
      expect((await retry.execute(plan)).state, CleanupState.complete);
    },
  );
}
