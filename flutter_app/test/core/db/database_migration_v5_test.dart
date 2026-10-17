import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:simpastil/core/db/database.dart';

import '../../fixtures/legacy_v3_database.dart';
import '../../fixtures/legacy_v5_fixture.dart';

void main() {
  test(
    'v4 inventory delta constraint preserves history and accepts doses',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'simpastil-v4-fixture-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final file = File('${scratch.path}/fictional-care.db');
      final source = sqlite3.open(file.path);
      seedLegacyV3(source);
      source.close();
      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      await freezeLegacyV5Fixture(seed);
      await seed.close();

      final historical = sqlite3.open(file.path);
      final sql =
          historical
                  .select(
                    "SELECT sql FROM sqlite_master WHERE name='inventory_events'",
                  )
                  .single['sql']
              as String;
      final v4 = sql
          .replaceFirst('"inventory_events"', '"inventory_events_v4"')
          .replaceFirst('"delta" IS NOT 0', '"delta" = 0');
      expect(v4, contains('"delta" = 0'));
      historical.execute(v4);
      historical.execute(
        'INSERT INTO inventory_events_v4 SELECT * FROM inventory_events',
      );
      historical.execute('DROP TABLE inventory_events');
      historical.execute(
        'ALTER TABLE inventory_events_v4 RENAME TO inventory_events',
      );
      historical.userVersion = 4;
      historical.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final openingEvents = await db.select(db.inventoryEvents).get();
      expect(openingEvents, hasLength(1));
      expect(openingEvents.single.delta, 10);
      await db.customStatement('''
      INSERT INTO inventory_events
        (id, user_id, pill_id, command_id, kind, delta, origin, recorded_at)
      VALUES ('dose-1', 'user-1', 'pill-1', 'command-dose', 'dose', -1, 'native', 2000)
    ''');
      expect(await db.medicationLedgerDao.getInventoryBalance('pill-1'), 9);
      expect(
        (await db.select(db.careWorkspaces).get()).single.bindingState,
        'unresolved',
      );
    },
  );
}
