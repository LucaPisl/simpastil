import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/protected_database.dart';
import 'package:sqlite3/sqlite3.dart';

class _Keys implements DeviceDatabaseKeyStore {
  String? value;
  int reads = 0;
  int writes = 0;
  @override
  Future<String?> read() async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String key) async {
    writes++;
    value = key;
  }
}

class _Interrupted implements Exception {}

void main() {
  late Directory scratch;
  late Directory root;
  late File legacy;
  late _Keys keys;
  late int migrations;
  Future<void> migrate(PreparedDatabase candidate) async {
    migrations++;
    final db = sqlite3.open(candidate.file.path);
    try {
      candidate.configure(db);
      db.execute(
        'CREATE TABLE IF NOT EXISTS care (id TEXT PRIMARY KEY, delivery TEXT)',
      );
      db.execute('CREATE TABLE IF NOT EXISTS migrated (id TEXT)');
      db.userVersion = 5;
      db.execute('PRAGMA journal_mode=WAL');
    } finally {
      db.close();
    }
  }

  ProtectedStoreCoordinator coordinator({
    Future<void> Function(PreparationPoint)? onPoint,
    CandidateMigration? migration,
    Future<void> Function(String)? sync,
    Duration limit = const Duration(seconds: 3),
    Duration gateLimit = const Duration(minutes: 2),
  }) => ProtectedStoreCoordinator(
    root: root,
    legacy: legacy,
    keyStore: keys,
    expectedSchema: 5,
    migrateCandidate: migration ?? migrate,
    syncDirectory: sync ?? (_) async {},
    onPoint: onPoint,
    acquisitionLimit: limit,
    preparationWaitLimit: gateLimit,
  );
  Database seed(int version) {
    final db = sqlite3.open(legacy.path);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA wal_autocheckpoint=0');
    db.execute('CREATE TABLE care (id TEXT PRIMARY KEY, delivery TEXT)');
    db.execute("INSERT INTO care VALUES ('stable-fictional-id', 'uncertain')");
    db.userVersion = version;
    return db;
  }

  Map<String, dynamic> marker() =>
      jsonDecode(File('${root.path}/store.json').readAsStringSync())
          as Map<String, dynamic>;
  Matcher failure(ProtectedStoreFailureCode code) => throwsA(
    isA<ProtectedStoreFailure>().having(
      (failure) => failure.code,
      'code',
      code,
    ),
  );
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('simpastil-coordinator-');
    root = Directory('${scratch.path}/private');
    legacy = File('${scratch.path}/legacy.db');
    keys = _Keys();
    migrations = 0;
  });
  tearDown(() async => scratch.delete(recursive: true));

  for (final version in [3, 4, 5]) {
    for (final stop in PreparationPoint.values) {
      test(
        'v$version interruption at ${stop.name} preserves WAL care and retries',
        () async {
          final source = seed(version);
          try {
            await expectLater(
              coordinator(
                onPoint: (point) async {
                  if (point == stop) throw _Interrupted();
                },
              ).prepare(),
              throwsA(isA<_Interrupted>()),
            );
            expect(source.userVersion, version);
            expect(
              source.select('SELECT delivery FROM care').single['delivery'],
              'uncertain',
            );
            final ready = await coordinator().prepare();
            final active = ready.openEstablished();
            try {
              expect(active.userVersion, 5);
              expect(
                active.select('SELECT id, delivery FROM care').single.values,
                ['stable-fictional-id', 'uncertain'],
              );
            } finally {
              active.close();
            }
            final recovery = sqlite3.open(
              ready.recovery!.path,
              mode: OpenMode.readWrite,
            );
            try {
              ready.configure(recovery);
              expect(recovery.userVersion, version);
              expect(
                recovery.select('SELECT delivery FROM care').single['delivery'],
                'uncertain',
              );
            } finally {
              recovery.close();
            }
            final count = migrations;
            await coordinator().prepare();
            expect(migrations, count);
            expect(marker()['state'], 'ready');
            expect(
              ready.legacyRetirement,
              LegacyRetirementStatus.pending,
              reason: 'Another live legacy reader prevents journal retirement',
            );
          } finally {
            source.close();
          }
        },
      );
    }
  }

  test('concurrent openers create one device key and one generation', () async {
    final ready = await Future.wait([
      coordinator().prepare(),
      coordinator().prepare(),
    ]);
    expect(keys.writes, 1);
    expect(migrations, 1);
    expect(ready[0].file.path, ready[1].file.path);
  });
  test(
    'a second opener waits out a migration longer than writer acquisition',
    () async {
      // First launch after an update: a background engine (widget refresh,
      // background sync, notification action) and the foreground both open
      // care while one of them migrates a large store.
      final slow = coordinator(
        limit: const Duration(milliseconds: 40),
        migration: (candidate) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          await migrate(candidate);
        },
      );
      final ready = await Future.wait([
        slow.prepare(),
        coordinator(limit: const Duration(milliseconds: 40)).prepare(),
      ]);
      expect(migrations, 1);
      expect(ready[0].file.path, ready[1].file.path);
      expect(marker()['state'], 'ready');
    },
  );
  test('a busy gate refuses before key lookup or preparation', () async {
    await root.create();
    final gate = sqlite3.open('${root.path}/preparation.sqlite');
    gate.execute('BEGIN EXCLUSIVE');
    try {
      await expectLater(
        coordinator(gateLimit: const Duration(milliseconds: 40)).prepare(),
        failure(ProtectedStoreFailureCode.busy),
      );
      expect(keys.reads, 0);
      expect(keys.writes, 0);
      expect(await File('${root.path}/store.json').exists(), isFalse);
    } finally {
      gate.execute('ROLLBACK');
      gate.close();
    }
  });
  test('a wrong key does not alter active care or replace its key', () async {
    final ready = await coordinator().prepare();
    final bytes = await ready.file.readAsBytes();
    final metadata = await File('${root.path}/store.json').readAsString();
    keys.value = base64Url.encode(List<int>.filled(32, 7));
    await expectLater(
      coordinator().prepare(),
      failure(ProtectedStoreFailureCode.unreadableStore),
    );
    expect(keys.writes, 1);
    expect(await ready.file.readAsBytes(), bytes);
    expect(await File('${root.path}/store.json').readAsString(), metadata);
  });
  test(
    'missing established file cannot be recreated at actual opening',
    () async {
      final ready = await coordinator().prepare();
      await ready.file.delete();
      expect(
        ready.openEstablished,
        failure(ProtectedStoreFailureCode.activeStoreMissing),
      );
      expect(await ready.file.exists(), isFalse);
      await expectLater(
        coordinator().prepare(),
        failure(ProtectedStoreFailureCode.activeStoreMissing),
      );
      expect(await ready.file.exists(), isFalse);
    },
  );
  test('an established empty file cannot initialize new care', () async {
    final ready = await coordinator().prepare();
    await ready.file.writeAsBytes([]);
    expect(
      ready.openEstablished,
      failure(ProtectedStoreFailureCode.unreadableStore),
    );
    expect(await ready.file.length(), 0);
  });
  test(
    'unknown generation without a pointer blocks fresh initialization',
    () async {
      await Directory(
        '${root.path}/generation-unrecognized',
      ).create(recursive: true);
      await expectLater(
        coordinator().prepare(),
        failure(ProtectedStoreFailureCode.invalidMarker),
      );
      expect(keys.writes, 0);
      expect(migrations, 0);
    },
  );
  test(
    'lost legacy source during interrupted migration cannot become empty care',
    () async {
      seed(3).close();
      await expectLater(
        coordinator(
          onPoint: (point) async {
            if (point == PreparationPoint.inspecting) throw _Interrupted();
          },
        ).prepare(),
        throwsA(isA<_Interrupted>()),
      );
      await legacy.delete();
      await expectLater(
        coordinator().prepare(),
        failure(ProtectedStoreFailureCode.activeStoreMissing),
      );
      expect(marker()['active'], isNull);
    },
  );
  test(
    'out-of-space migration preserves original and verified protected recovery',
    () async {
      final source = seed(3);
      source.close();
      await expectLater(
        coordinator(
          migration: (_) async {
            throw const FileSystemException(
              'fixture',
              '',
              OSError('fixture', 28),
            );
          },
        ).prepare(),
        failure(ProtectedStoreFailureCode.insufficientSpace),
      );
      expect(marker()['active'], isNull);
      expect(await legacy.exists(), isTrue);
      final pending = marker()['pending'];
      final recovery = sqlite3.open(
        '${root.path}/$pending/recovery.db',
        mode: OpenMode.readWrite,
      );
      recovery.execute("PRAGMA cipher='chacha20'");
      recovery.execute("PRAGMA key='${keys.value}'");
      try {
        expect(
          recovery.select('SELECT delivery FROM care').single['delivery'],
          'uncertain',
        );
      } finally {
        recovery.close();
      }
      final ready = await coordinator().prepare();
      expect(ready.legacyRetirement, LegacyRetirementStatus.retired);
    },
  );
  test(
    'damaged original recovery refuses plaintext retirement while active care stays available',
    () async {
      seed(3).close();
      final ready = await coordinator(
        onPoint: (point) async {
          if (point == PreparationPoint.activeReopened) {
            final generation = marker()['recovery'];
            final copy = sqlite3.open(
              '${root.path}/$generation/recovery.db',
              mode: OpenMode.readWrite,
            );
            copy.execute("PRAGMA cipher='chacha20'");
            copy.execute("PRAGMA key='${keys.value}'");
            try {
              copy.execute(
                "UPDATE care SET delivery='damaged' WHERE id='stable-fictional-id'",
              );
            } finally {
              copy.close();
            }
          }
        },
      ).prepare();
      expect(ready.legacyRetirement, LegacyRetirementStatus.pending);
      expect(await legacy.exists(), isTrue);
      final opened = ready.openEstablished();
      try {
        expect(
          opened.select('SELECT delivery FROM care').single['delivery'],
          'uncertain',
        );
      } finally {
        opened.close();
      }
    },
  );

  test(
    'failed legacy-parent sync is retried before retirement completion',
    () async {
      seed(3).close();
      var legacySyncs = 0;
      Future<void> directorySync(String path) async {
        if (path == scratch.path) {
          legacySyncs++;
          if (legacySyncs == 1) {
            throw const FileSystemException('fictional sync failure');
          }
        }
      }

      final first = await coordinator(sync: directorySync).prepare();
      expect(first.legacyRetirement, LegacyRetirementStatus.pending);
      expect(await legacy.exists(), isFalse);
      expect(marker()['retirement']['state'], 'deleting');
      final retried = await coordinator(sync: directorySync).prepare();
      expect(legacySyncs, 2);
      expect(retried.legacyRetirement, LegacyRetirementStatus.retired);
    },
  );
}
