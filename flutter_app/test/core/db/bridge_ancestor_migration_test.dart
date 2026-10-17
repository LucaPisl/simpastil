import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:simpastil/core/db/database.dart';

import '../../fixtures/legacy_v3_database.dart';

void main() {
  for (final publishedVersion in [11, 12, 13]) {
    test(
      'schema$publishedVersion upgrade retains care, checkpoints and staged pages',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'fictional-bridge-v11-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/care.sqlite');
        final raw = sqlite3.open(file.path);
        seedLegacyV3(raw);
        raw.close();
        final seed = AppDatabase(NativeDatabase(file));
        await seed.customSelect('SELECT 1').get();
        // Keep one occurrence event in the historical file. The v14 column
        // must be added as NULL when an older backup is opened.
        await seed.customStatement('''
      INSERT INTO medication_occurrences
        (id, user_id, pill_id, schedule_id, occurrence_key, source,
         planned_local_date, planned_local_time, time_zone, expected,
         snapshot_version, schedule_snapshot_json, provenance, created_at,
         updated_at)
      VALUES ('occurrence-1', 'user-1', 'pill-1', 'schedule-1',
              'historical-occurrence', 'scheduled', '2026-10-01', '08:00',
              'UTC', 0, 1, '{}', 'exact', 1760000000000, 1760000000000)
    ''');
        await seed.customStatement('''
      INSERT INTO occurrence_events
        (id, user_id, occurrence_id, command_id, action, from_state,
         to_state, actual_time_known, origin, base_version, result_version,
         recorded_at)
      VALUES ('occurrence-event-1', 'user-1', 'occurrence-1', 'command-1',
              'take', 'pending', 'taken', 0, 'native', 0, 1,
              1760000000000)
    ''');
        await seed.customStatement('''
      INSERT INTO sync_component_states
        (user_id, component, contract_version, last_completed_cursor,
         last_full_success_at, current_state, diagnostic_metadata_json)
      VALUES ('user-1', 'medicationBridge', 2, 'retained-cursor', 1000,
              'partial', '{"stage":"retained"}')
    ''');
        for (final finalPage in [0, 1]) {
          await seed.customStatement('''
        INSERT INTO sync_staging_runs
          (id, user_id, component, contract_version, after_sequence,
           through_sequence, next_cursor, page_count, final_page_received, started_at)
        VALUES ('run-$finalPage', 'user-1', 'medicationBridge', 2, '1', '3',
                'retained-page-$finalPage', 1, $finalPage, 1000)
      ''');
          await seed.customStatement('''
        INSERT INTO sync_staging_items
          (run_id, server_sequence, entity_type, entity_id, payload_json)
        VALUES ('run-$finalPage', 2, 'bridge_dose', 'fictional-dose',
                '{"fictional":"retained unmerged evidence"}')
      ''');
        }
        Future<Map<String, String>> snapshot(AppDatabase database) async {
          Map<String, Object?> canonicalRow(Map<String, Object?> row) {
            final keys = row.keys.toList()..sort();
            return {for (final key in keys) key: row[key]};
          }

          return {
            for (final table in database.allTables)
              table.actualTableName: jsonEncode(
                (await database
                        .customSelect(
                          'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
                        )
                        .get())
                    .map((row) => canonicalRow(row.data))
                    .toList(),
              ),
          };
        }

        final before = await snapshot(seed);
        await seed.close();

        // Reconstruct the published shape in this fictional file. The v14
        // additions must be absent so opening it actually exercises the
        // corresponding migration branch.
        final historical = sqlite3.open(file.path);
        historical.execute('PRAGMA foreign_keys=OFF');
        // The seed database was opened in WAL mode. Collapse it before a
        // second connection reopens the deliberately older schema.
        historical.execute('PRAGMA journal_mode=DELETE');
        historical.execute('DROP TABLE effect_settlements');
        historical.execute(
          'ALTER TABLE schedules DROP COLUMN time_zone_status',
        );
        historical.execute('ALTER TABLE schedules DROP COLUMN time_zone');
        // Rebuild this table instead of relying on DROP COLUMN: older SQLite
        // builds can leave a stale table schema for a second connection.
        final occurrenceSql =
            historical
                    .select(
                      "SELECT sql FROM sqlite_master WHERE name='occurrence_events'",
                    )
                    .single['sql']
                as String;
        final oldOccurrenceColumns = [
          'id',
          'server_id',
          'user_id',
          'occurrence_id',
          'command_id',
          'action',
          'from_state',
          'to_state',
          'reverses_event_id',
          'rebases_command_id',
          'actual_at',
          'actual_time_known',
          'note',
          'origin',
          'base_version',
          'result_version',
          'server_sequence',
          'recorded_at',
        ];
        // SQLite may have already discarded the generated index while the
        // historical table is being rewritten; recreate the published index
        // below after restoring the old table shape.
        historical.execute(
          'DROP INDEX IF EXISTS occurrence_events_user_occurrence_recorded',
        );
        historical.execute(
          occurrenceSql
              .replaceFirst('"occurrence_events"', '"occurrence_events_old"')
              .replaceFirst(', "administration_amount_json" TEXT NULL', ''),
        );
        historical.execute(
          'INSERT INTO occurrence_events_old (${oldOccurrenceColumns.join(',')}) '
          'SELECT ${oldOccurrenceColumns.join(',')} FROM occurrence_events',
        );
        historical.execute('DROP TABLE occurrence_events');
        historical.execute(
          'ALTER TABLE occurrence_events_old RENAME TO occurrence_events',
        );
        historical.execute(
          'CREATE INDEX occurrence_events_user_occurrence_recorded '
          'ON occurrence_events(user_id, occurrence_id, recorded_at)',
        );
        expect(
          historical
              .select("PRAGMA table_info('occurrence_events')")
              .map((row) => row['name']),
          isNot(contains('administration_amount_json')),
        );
        for (final table in ['sync_component_states', 'sync_staging_runs']) {
          final sql =
              historical.select('SELECT sql FROM sqlite_master WHERE name=?', [
                    table,
                  ]).single['sql']
                  as String;
          final maxContract = switch (publishedVersion) {
            11 => 'IN (1, 2)',
            12 => 'IN (1, 2, 3)',
            _ => 'IN (1, 2, 3, 4)',
          };
          final old = sql
              .replaceFirst('"$table"', '"${table}_v$publishedVersion"')
              .replaceFirst(
                RegExp(r'IN \(1, 2(?:, 3)?(?:, 4)?(?:, 5)?\)'),
                maxContract,
              );
          expect(old, contains(maxContract));
          historical.execute(old);
          historical.execute(
            'INSERT INTO ${table}_v$publishedVersion SELECT * FROM $table',
          );
          historical.execute('DROP TABLE $table');
          historical.execute(
            'ALTER TABLE ${table}_v$publishedVersion RENAME TO $table',
          );
        }
        historical.execute(
          'CREATE INDEX sync_staging_runs_user_component ON sync_staging_runs(user_id, component)',
        );
        historical.userVersion = publishedVersion;
        expect(historical.userVersion, publishedVersion);
        historical.close();

        final upgraded = AppDatabase(
          NativeDatabase(
            file,
            setup: (raw) {
              raw.execute('PRAGMA foreign_keys=ON');
            },
          ),
        );
        addTearDown(upgraded.close);
        expect(await snapshot(upgraded), before);
        expect(
          (await upgraded.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          AppDatabase.supportedSchemaVersion,
        );
        expect(
          await upgraded.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
        expect(
          (await upgraded.customSelect('PRAGMA foreign_keys').getSingle())
              .read<int>('foreign_keys'),
          1,
        );
        final upgradedSchedule = await upgraded
            .customSelect(
              'SELECT time_zone, time_zone_status FROM schedules WHERE id=?',
              variables: [const Variable<String>('schedule-1')],
            )
            .getSingle();
        expect(upgradedSchedule.read<String?>('time_zone'), isNull);
        expect(
          upgradedSchedule.read<String>('time_zone_status'),
          'legacy_unknown',
        );
        final upgradedEvent = await upgraded
            .customSelect(
              'SELECT administration_amount_json FROM occurrence_events WHERE id=?',
              variables: [const Variable<String>('occurrence-event-1')],
            )
            .getSingle();
        expect(
          upgradedEvent.read<String?>('administration_amount_json'),
          isNull,
        );
        expect(
          await upgraded.select(upgraded.effectSettlements).get(),
          isEmpty,
        );
        expect(
          await upgraded
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='index' AND name='sync_staging_runs_user_component'",
              )
              .get(),
          hasLength(1),
        );
        await upgraded.customStatement(
          "UPDATE sync_component_states SET contract_version=4 WHERE component='medicationBridge'",
        );
        await upgraded.customStatement(
          "UPDATE sync_staging_runs SET contract_version=4",
        );
        expect(
          (await upgraded.select(upgraded.syncStagingItems).get()),
          hasLength(2),
        );
        await upgraded.syncStateDao.discardRun('run-0');
        expect(
          (await upgraded.select(upgraded.syncStagingItems).get()).single.runId,
          'run-1',
        );
        await upgraded.customStatement(
          'UPDATE sync_staging_runs SET contract_version=5',
        );
        expect(
          (await upgraded.select(upgraded.syncStagingRuns).get()).every(
            (run) => run.contractVersion == 5,
          ),
          isTrue,
        );
        await expectLater(
          upgraded.customStatement(
            'UPDATE sync_staging_runs SET contract_version=6',
          ),
          throwsA(isA<SqliteException>()),
        );
      },
    );
  }
}
