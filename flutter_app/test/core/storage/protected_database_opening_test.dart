import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
// Existing platform dependency; supplies isolated directories for opener tests.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/storage/protected_database.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../fixtures/legacy_v3_database.dart';
import '../../fixtures/legacy_v5_fixture.dart';
import '../../fixtures/verified_schema_compatibility.dart';

class _Directories extends PathProviderPlatform {
  _Directories(this.root);
  final String root;
  @override
  Future<String> getApplicationDocumentsPath() async => '$root/documents';
  @override
  Future<String> getApplicationSupportPath() async => '$root/private';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late PathProviderPlatform previousDirectories;
  late Map<String, String> deviceKeys;
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const storageChannel = MethodChannel('simpastil_storage');

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp(
      'simpastil-protected-open-',
    );
    await Directory('${scratch.path}/documents').create();
    await Directory('${scratch.path}/private').create();
    previousDirectories = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Directories(scratch.path);
    deviceKeys = {};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'read':
          return deviceKeys[args['key']];
        case 'write':
          deviceKeys[args['key']] = args['value'] as String;
          return null;
        case 'delete':
          deviceKeys.remove(args['key']);
          return null;
        default:
          throw StateError('Unexpected secure-storage operation');
      }
    });
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      switch (call.method) {
        case 'noBackupPath':
          return '${scratch.path}/private';
        case 'syncDirectory':
          return null;
        case 'availableBytes':
          return 1024 * 1024 * 1024;
        default:
          throw StateError('Unexpected private-storage operation');
      }
    });
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousDirectories;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureChannel, null);
    messenger.setMockMethodCallHandler(storageChannel, null);
    await scratch.delete(recursive: true);
  });

  test(
    'fresh default opening never creates a plaintext care database',
    () async {
      final db = AppDatabase();
      try {
        await db.customSelect('SELECT 1').get();
      } finally {
        await db.close();
      }
      expect(
        await File('${scratch.path}/documents/simpastil.db').exists(),
        isFalse,
        reason:
            'Normal opening must create protected care, not plaintext SQLite',
      );
      expect(
        deviceKeys,
        isNotEmpty,
        reason: 'The independent device key must be persisted',
      );
    },
  );

  for (final publishedVersion in [11, 12]) {
    test(
      'protected schema$publishedVersion upgrade retains its key, author and staged pages',
      () async {
        final previous = AppDatabase();
        final context = await WorkspaceAccessRepository(
          previous,
          effectsGate: SerialProjectionEffectsGate(),
        ).currentContext();
        final originalKeys = Map<String, String>.from(deviceKeys);
        await previous.customStatement(
          '''INSERT INTO sync_component_states
      (user_id, component, contract_version, last_completed_cursor, current_state)
      VALUES (?, 'medicationBridge', 2, 'retained-checkpoint', 'partial')''',
          [context.ownerUserId],
        );
        await previous.customStatement(
          '''INSERT INTO sync_staging_runs
      (id, user_id, component, contract_version, after_sequence, through_sequence,
       next_cursor, page_count, final_page_received, started_at)
      VALUES ('fictional-stage', ?, 'medicationBridge', 2, '0', '1',
       'retained-page', 1, 0, 1000)''',
          [context.ownerUserId],
        );
        await previous.customStatement(
          '''INSERT INTO sync_staging_items
      (run_id, server_sequence, entity_type, entity_id, payload_json)
      VALUES ('fictional-stage', 1, 'bridge_dose', 'fictional-dose', '{"retained":true}')''',
        );
        Future<String> stagedFacts(AppDatabase db) async => jsonEncode({
          for (final name in [
            'sync_component_states',
            'sync_staging_runs',
            'sync_staging_items',
          ])
            name: (await db.customSelect('SELECT * FROM $name').get())
                .map((r) => r.data)
                .toList(),
        });
        final before = await stagedFacts(previous);
        await previous.customStatement('PRAGMA foreign_keys=OFF');
        await previous.customStatement('DROP TABLE effect_settlements');
        await previous.customStatement(
          'ALTER TABLE schedules DROP COLUMN time_zone_status',
        );
        await previous.customStatement(
          'ALTER TABLE schedules DROP COLUMN time_zone',
        );
        await previous.customStatement(
          'ALTER TABLE occurrence_events DROP COLUMN administration_amount_json',
        );
        for (final table in ['sync_component_states', 'sync_staging_runs']) {
          final sql =
              (await previous
                      .customSelect(
                        "SELECT sql FROM sqlite_master WHERE name='$table'",
                      )
                      .getSingle())
                  .read<String>('sql');
          final maxContract = publishedVersion == 11
              ? 'IN (1, 2)'
              : 'IN (1, 2, 3)';
          final old = sql
              .replaceFirst('"$table"', '"${table}_v$publishedVersion"')
              .replaceFirst(
                RegExp(r'IN \(1, 2(?:, 3)?(?:, 4)?(?:, 5)?\)'),
                maxContract,
              );
          expect(old, contains(maxContract));
          await previous.customStatement(old);
          await previous.customStatement(
            'INSERT INTO ${table}_v$publishedVersion SELECT * FROM $table',
          );
          await previous.customStatement('DROP TABLE $table');
          await previous.customStatement(
            'ALTER TABLE ${table}_v$publishedVersion RENAME TO $table',
          );
        }
        await previous.customStatement(
          'CREATE INDEX sync_staging_runs_user_component ON sync_staging_runs(user_id, component)',
        );
        await previous.customStatement('PRAGMA user_version=$publishedVersion');
        await previous.close();
        final manifestFile = File('${scratch.path}/private/care/store.json');
        final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
        manifest['targetSchema'] = publishedVersion;
        await manifestFile.writeAsString(jsonEncode(manifest));
        final current = AppDatabase();
        addTearDown(current.close);
        expect(await stagedFacts(current), before);
        final retained = await WorkspaceAccessRepository(
          current,
          effectsGate: SerialProjectionEffectsGate(),
        ).currentContext();
        expect(retained.workspaceId, context.workspaceId);
        expect(retained.authorId, context.authorId);
        expect(deviceKeys, originalKeys);
        expect(
          (await current.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          AppDatabase.supportedSchemaVersion,
        );
        expect(
          await current.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
        await current.customStatement(
          "UPDATE sync_staging_runs SET contract_version=4",
        );
      },
    );
  }
  test(
    'published protected schema6 upgrades to14 with its key and local author retained',
    () async {
      final previous = AppDatabase();
      final oldAccess = WorkspaceAccessRepository(
        previous,
        effectsGate: SerialProjectionEffectsGate(),
      );
      final oldContext = await oldAccess.currentContext();
      final originalKeys = Map<String, String>.from(deviceKeys);
      // Disposable known v6 shape: remove every later additive table.
      expect(AppDatabase.supportedSchemaVersion, 25);
      await stripSchema14Additions(previous);
      await previous.customStatement('DROP TABLE device_restore_intents');
      await previous.customStatement('DROP TABLE import_conflicts');
      await previous.customStatement('DROP TABLE import_evidence');
      await previous.customStatement('DROP TABLE import_receipts');
      await previous.customStatement('DROP TABLE device_schedule_reminders');
      await previous.customStatement('DROP TABLE device_reminder_settings');
      await previous.customStatement('DROP TABLE care_event_details');
      await previous.customStatement('DROP TABLE reviewed_stock_balances');
      await previous.customStatement('DROP TABLE local_routines');
      await previous.customStatement('DROP TABLE setup_drafts');
      await previous.customStatement('DROP TABLE medication_details');
      await previous.customStatement('PRAGMA user_version=6');
      await previous.close();
      final manifestFile = File('${scratch.path}/private/care/store.json');
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
      manifest['targetSchema'] = 6;
      await manifestFile.writeAsString(jsonEncode(manifest));
      final current = AppDatabase();
      try {
        final context = await WorkspaceAccessRepository(
          current,
          effectsGate: SerialProjectionEffectsGate(),
        ).currentContext();
        expect(context.workspaceId, oldContext.workspaceId);
        expect(context.authorId, oldContext.authorId);
        expect(deviceKeys, originalKeys);
        expect(await current.select(current.setupDrafts).get(), isEmpty);
        expect(await current.select(current.medicationDetails).get(), isEmpty);
        expect(
          (await current.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          AppDatabase.supportedSchemaVersion,
        );
      } finally {
        await current.close();
      }
    },
  );

  test(
    'a missing established device key refuses opening instead of fresh care',
    () async {
      final first = AppDatabase();
      await first.customSelect('SELECT 1').get();
      await first.close();
      deviceKeys.clear();
      final reopened = AppDatabase();
      try {
        await expectLater(
          reopened.customSelect('SELECT 1').get(),
          throwsA(
            isA<ProtectedStoreFailure>().having(
              (failure) => failure.code,
              'code',
              ProtectedStoreFailureCode.keyMissing,
            ),
          ),
        );
      } finally {
        await reopened.close();
      }
    },
  );

  test(
    'future legacy schema is refused without downgrading its original',
    () async {
      final file = File('${scratch.path}/documents/simpastil.db');
      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      await seed.customStatement('PRAGMA user_version=99');
      await seed.close();
      final reopened = AppDatabase();
      try {
        await expectLater(
          reopened.customSelect('SELECT 1').get(),
          throwsA(
            isA<ProtectedStoreFailure>().having(
              (failure) => failure.code,
              'code',
              ProtectedStoreFailureCode.unsupportedSchema,
            ),
          ),
        );
      } finally {
        await reopened.close();
      }
      // Raw inspection must not trigger schema negotiation again.
      final inspection = sqlite3.open(file.path, mode: OpenMode.readOnly);
      try {
        expect(inspection.userVersion, 99);
      } finally {
        inspection.close();
      }
    },
  );

  test(
    'a newer preparation marker is refused without overwriting it',
    () async {
      final initial = AppDatabase();
      await initial.customSelect('SELECT 1').get();
      await initial.close();
      final markerFile = File('${scratch.path}/private/care/store.json');
      final marker = jsonDecode(await markerFile.readAsString()) as Map;
      marker['targetSchema'] = 99;
      final futureMarker = jsonEncode(marker);
      await markerFile.writeAsString(futureMarker);
      final reopened = AppDatabase();
      try {
        await expectLater(
          reopened.customSelect('SELECT 1').get(),
          throwsA(
            isA<ProtectedStoreFailure>().having(
              (failure) => failure.code,
              'code',
              ProtectedStoreFailureCode.unsupportedSchema,
            ),
          ),
        );
      } finally {
        await reopened.close();
      }
      expect(await markerFile.readAsString(), futureMarker);
    },
  );

  test(
    'a legacy database claiming v5 with a missing table is never published',
    () async {
      final file = File('${scratch.path}/documents/simpastil.db');
      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      await seed.customStatement('DROP TABLE sync_staging_items');
      await seed.close();
      final before = await file.readAsBytes();
      final reopened = AppDatabase();
      try {
        await expectLater(
          reopened.customSelect('SELECT 1').get(),
          throwsA(
            isA<ProtectedStoreFailure>().having(
              (failure) => failure.code,
              'code',
              ProtectedStoreFailureCode.migrationFailed,
            ),
          ),
        );
      } finally {
        await reopened.close();
      }
      expect(await file.readAsBytes(), before);
      final marker =
          jsonDecode(
                await File(
                  '${scratch.path}/private/care/store.json',
                ).readAsString(),
              )
              as Map;
      expect(marker['active'], isNull);
    },
  );

  for (final version in [3, 4, 5]) {
    test(
      'complete v$version care is protected with original recovery and safe plaintext retirement',
      () async {
        final file = File('${scratch.path}/documents/simpastil.db');
        final raw = sqlite3.open(file.path);
        seedLegacyV3(raw);
        raw.close();
        if (version > 3) {
          final seed = AppDatabase(NativeDatabase(file));
          await seed.customSelect('SELECT 1').get();
          await freezeLegacyV5Fixture(seed);
          await seed.close();
          if (version == 4) {
            // Full v4 differs from v5 only in the inventory delta CHECK.
            final db = sqlite3.open(file.path);
            final sql =
                db
                        .select(
                          "SELECT sql FROM sqlite_master WHERE name='inventory_events'",
                        )
                        .single['sql']
                    as String;
            final historical = sql
                .replaceFirst('"inventory_events"', '"inventory_events_v4"')
                .replaceFirst(
                  '"delta" TEXT NOT NULL CHECK("delta" IS NOT \'0\'',
                  '"delta" INTEGER NOT NULL CHECK("delta" = 0',
                );
            expect(historical, contains('"delta" = 0'));
            expect(historical, isNot(contains('"delta" IS NOT')));
            db.execute(historical);
            db.execute(
              'INSERT INTO inventory_events_v4 SELECT * FROM inventory_events',
            );
            db.execute('DROP TABLE inventory_events');
            db.execute(
              'ALTER TABLE inventory_events_v4 RENAME TO inventory_events',
            );
            db.execute(
              'CREATE INDEX inventory_events_user_pill_recorded ON inventory_events(user_id, pill_id, recorded_at)',
            );
            db.userVersion = 4;
            db.close();
          }
        }
        final original = sqlite3.open(file.path);
        final schema = original
            .select(
              "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
            )
            .map((row) => row['name'])
            .toList();
        final sourceLogs = original.select(
          'SELECT id, sync_status FROM dose_logs ORDER BY id',
        );
        final snapshotLogs = sourceLogs
            .map((row) => Map<String, Object?>.from(row))
            .toList();
        original.close();
        final protected = AppDatabase();
        try {
          await protected.customSelect('SELECT 1').get();
          await verifyLegacySchemaCompatibility(
            protected,
            deviceKeys.values.single,
            scratch,
          );
          expect(
            await protected.doseLogsDao.getByScheduleId('schedule-1'),
            hasLength(2),
          );
          expect(
            await protected.select(protected.pendingOperations).get(),
            hasLength(3),
          );
          expect(
            (await protected.select(protected.pendingOperationEffects).get())
                .every((row) => row.state == 'uncertain'),
            isTrue,
          );
          expect(
            await protected.medicationLedgerDao.getInventoryBalance('pill-1'),
            ExactStock.fromInt(10),
          );
        } finally {
          await protected.close();
        }
        final marker =
            jsonDecode(
                  await File(
                    '${scratch.path}/private/care/store.json',
                  ).readAsString(),
                )
                as Map;
        final recoveryFile = File(
          '${scratch.path}/private/care/${marker['recovery']}/recovery.db',
        );
        final key = deviceKeys.values.single;
        final recovery = sqlite3.open(
          recoveryFile.path,
          mode: OpenMode.readWrite,
        );
        try {
          recovery.execute("PRAGMA cipher='chacha20'");
          recovery.execute("PRAGMA key='$key'");
          expect(recovery.userVersion, version);
          expect(
            recovery
                .select(
                  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
                )
                .map((row) => row['name'])
                .toList(),
            schema,
          );
          expect(
            recovery
                .select('SELECT id, sync_status FROM dose_logs ORDER BY id')
                .map((row) => Map<String, Object?>.from(row))
                .toList(),
            snapshotLogs,
          );
        } finally {
          recovery.close();
        }
        final bytes = await recoveryFile.readAsBytes();
        expect(
          utf8.decode(bytes.take(16).toList(), allowMalformed: true),
          isNot(startsWith('SQLite format 3')),
        );
        expect(
          utf8.decode(bytes, allowMalformed: true),
          isNot(contains('dose-1')),
        );
        expect(
          await file.exists(),
          isFalse,
          reason:
              'Plaintext retirement requires both verified protected copies',
        );
        expect(marker['retirement']['state'], 'retired');
      },
    );
  }

  test(
    'warm legacy protection refuses a removed server identity constraint',
    () async {
      final legacy = sqlite3.open('${scratch.path}/documents/simpastil.db');
      seedLegacyV3(legacy);
      legacy.close();
      final initial = AppDatabase();
      await initial.customSelect('SELECT 1').get();
      await initial.close();
      final marker =
          jsonDecode(
                await File(
                  '${scratch.path}/private/care/store.json',
                ).readAsString(),
              )
              as Map;
      final file = File(
        '${scratch.path}/private/care/${marker['active']}/care.db',
      );
      final raw = sqlite3.open(file.path, mode: OpenMode.readWrite);
      raw.execute("PRAGMA cipher='chacha20'");
      raw.execute("PRAGMA key='${deviceKeys.values.single}'");
      raw.execute('DROP INDEX profiles_server_id_unique');
      raw.close();
      final reopened = AppDatabase();
      try {
        await expectLater(
          reopened.customSelect('SELECT 1').get(),
          throwsA(
            isA<ProtectedStoreFailure>().having(
              (failure) => failure.code,
              'code',
              ProtectedStoreFailureCode.migrationFailed,
            ),
          ),
        );
      } finally {
        await reopened.close();
      }
    },
  );

  for (final alteration in [
    'ALTER TABLE refresh_tokens DROP COLUMN family_id',
    'DROP INDEX inventory_events_user_pill_recorded; CREATE INDEX inventory_events_user_pill_recorded ON inventory_events(user_id)',
    'DROP TRIGGER profiles_first_seen',
    "DROP TRIGGER profiles_first_seen; CREATE TRIGGER profiles_first_seen AFTER INSERT ON profiles BEGIN SELECT 1; END",
  ]) {
    test(
      'warm protected store refuses altered required schema: $alteration',
      () async {
        final initial = AppDatabase();
        await initial.customSelect('SELECT 1').get();
        await initial.close();
        final marker =
            jsonDecode(
                  await File(
                    '${scratch.path}/private/care/store.json',
                  ).readAsString(),
                )
                as Map;
        final raw = sqlite3.open(
          '${scratch.path}/private/care/${marker['active']}/care.db',
          mode: OpenMode.readWrite,
        );
        raw.execute("PRAGMA cipher='chacha20'");
        raw.execute("PRAGMA key='${deviceKeys.values.single}'");
        raw.execute(alteration);
        raw.close();
        final reopened = AppDatabase();
        try {
          await expectLater(
            reopened.customSelect('SELECT 1').get(),
            throwsA(
              isA<ProtectedStoreFailure>().having(
                (failure) => failure.code,
                'code',
                ProtectedStoreFailureCode.migrationFailed,
              ),
            ),
          );
        } finally {
          await reopened.close();
        }
      },
    );
  }
}
