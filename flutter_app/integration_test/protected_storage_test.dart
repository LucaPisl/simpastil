import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/storage/device_database_key_store.dart';
import 'package:simpastil/core/storage/protected_database.dart';
import 'package:simpastil_storage/simpastil_storage.dart';
import 'package:sqlite3/sqlite3.dart';

import '../test/fixtures/legacy_v3_database.dart';
import '../test/fixtures/legacy_v5_fixture.dart';

/// Run only on the explicitly owned blank Simpastil_Test Android AVD.
/// `flutter run` preserves data for the second process-restart stage;
/// `flutter test` uninstalls the test application on completion.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('production protected storage on disposable Android', (
    tester,
  ) async {
    const authorized = bool.fromEnvironment('SIMPASTIL_DISPOSABLE_TEST');
    expect(
      authorized && Platform.isAndroid,
      isTrue,
      reason: 'Requires explicit disposable Android fixture authorization',
    );
    const native = SimpastilStorage();
    final root = Directory('${await native.noBackupPath()}/care');
    final documents = await getApplicationDocumentsDirectory();
    final legacy = File('${documents.path}/simpastil.db');
    const restart = String.fromEnvironment('RESTART_STAGE') == 'restart';
    if (!restart) {
      expect(
        await root.exists(),
        isFalse,
        reason: 'Run starts only on the owned blank test installation',
      );
      expect(await legacy.exists(), isFalse);
      final fresh = AppDatabase();
      await fresh.customSelect('SELECT 1').get();
      await fresh.close();
      expect(await legacy.exists(), isFalse);
      expect(await native.availableBytes(), isNonNegative);
      await native.syncDirectory(documents.path);
      for (final version in [3, 4, 5]) {
        await root.delete(recursive: true);
        final raw = sqlite3.open(legacy.path);
        seedLegacyV3(raw);
        raw.close();
        if (version > 3) {
          final seed = AppDatabase(NativeDatabase(legacy));
          await seed.customSelect('SELECT 1').get();
          await seed.customStatement(
            "INSERT INTO sync_staging_runs (id,user_id,component,contract_version,after_sequence,through_sequence,started_at) VALUES ('staging-1','user-1','medication',1,'0','5',1760000000)",
          );
          await seed.customStatement(
            "INSERT INTO sync_staging_items VALUES ('staging-1',1,'pill','pill-1','{}')",
          );
          await freezeLegacyV5Fixture(seed);
          await seed.close();
          if (version == 4) {
            final fixture = sqlite3.open(legacy.path);
            final sql =
                fixture
                        .select(
                          "SELECT sql FROM sqlite_master WHERE name='inventory_events'",
                        )
                        .single['sql']
                    as String;
            final historical = sql
                .replaceFirst('"inventory_events"', '"inventory_events_v4"')
                .replaceFirst('"delta" IS NOT 0', '"delta" = 0');
            expect(historical, contains('"delta" = 0'));
            fixture.execute(historical);
            fixture.execute(
              'INSERT INTO inventory_events_v4 SELECT * FROM inventory_events',
            );
            fixture.execute('DROP TABLE inventory_events');
            fixture.execute(
              'ALTER TABLE inventory_events_v4 RENAME TO inventory_events',
            );
            fixture.userVersion = 4;
            fixture.close();
          }
        }
        final db = AppDatabase();
        try {
          expect(
            await db.doseLogsDao.getByScheduleId('schedule-1'),
            hasLength(2),
          );
          expect(await db.select(db.pendingOperations).get(), hasLength(3));
          expect(
            (await db.select(db.pendingOperationEffects).get()).every(
              (effect) => effect.state == 'uncertain',
            ),
            isTrue,
          );
          expect(
            await db.medicationLedgerDao.getInventoryBalance('pill-1'),
            10,
          );
          expect(
            (await db.select(db.careWorkspaces).get()).single.bindingState,
            'unresolved',
          );
          expect(
            (await db.select(db.workspaceGrants).get()).single.isGranted,
            isFalse,
          );
          if (version > 3) {
            expect(await db.select(db.syncStagingItems).get(), hasLength(1));
          }
        } finally {
          await db.close();
        }
        expect(await legacy.exists(), isFalse);
        final marker =
            jsonDecode(await File('${root.path}/store.json').readAsString())
                as Map;
        expect(marker['retirement']['state'], 'retired');
        final copy = File('${root.path}/${marker['recovery']}/recovery.db');
        final evidence = await verifyProtectedDatabase(
          copy,
          const SecureDeviceDatabaseKeyStore(),
          5,
        );
        expect(evidence.schema, version);
        expect(evidence.rows['dose_logs'], 2);
        if (version > 3) expect(evidence.rows['sync_staging_items'], 1);
        expect(
          utf8.decode(await copy.readAsBytes(), allowMalformed: true),
          isNot(contains('dose-1')),
        );
      }
    } else {
      expect(
        await root.exists(),
        isTrue,
        reason: 'Actual restart must retain the first process fixture',
      );
      final db = AppDatabase();
      try {
        expect(
          await db.doseLogsDao.getByScheduleId('schedule-1'),
          hasLength(2),
        );
        expect(await db.select(db.pendingOperations).get(), hasLength(3));
        expect(
          (await db.select(db.pendingOperationEffects).get()).every(
            (effect) => effect.state == 'uncertain',
          ),
          isTrue,
        );
        expect(await db.select(db.syncStagingItems).get(), hasLength(1));
        expect(
          (await db.select(db.careWorkspaces).get()).single.bindingState,
          'unresolved',
        );
        expect(
          (await db.select(db.workspaceGrants).get()).single.isGranted,
          isFalse,
        );
      } finally {
        await db.close();
      }
      expect(await legacy.exists(), isFalse);
    }
    // Fictional pass summary only; never print paths, keys, rows or native SQL.
    // ignore: avoid_print
    print(
      restart
          ? 'PASS: production care and uncertain queue reopened after process restart'
          : 'PASS: native production first-open, full v3/v4/v5 migration, recovery, staging and plaintext retirement',
    );
  });
}
