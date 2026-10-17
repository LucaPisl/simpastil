import 'dart:io';

import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../generated_migrations/schema.dart';

/// Upgrades a genuine historical store (rebuilt from `drift_schemas/`, which
/// holds one snapshot per shipped schema version) to the current version, and
/// checks the result has exactly the current shape and keeps the caregiver's
/// rows. Hand-rewinding `user_version` on a current-shape database cannot
/// catch a step that is wrong for a genuinely old shape.
///
/// A store NEWER than this build is refused without mutation by the protected
/// opening path; that is pinned in
/// `test/core/storage/protected_database_opening_test.dart` ("future legacy
/// schema is refused without downgrading its original").
void main() {
  late SchemaVerifier verifier;
  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('a snapshot exists for every shipped version up to the current one', () {
    for (var v = 1; v <= AppDatabase.supportedSchemaVersion; v++) {
      expect(
        File('drift_schemas/drift_schema_v$v.json').existsSync(),
        isTrue,
        reason: 'run `dart run drift_dev schema dump` for version $v',
      );
    }
    expect(
      File(
        'drift_schemas/drift_schema_v${AppDatabase.supportedSchemaVersion + 1}'
        '.json',
      ).existsSync(),
      isFalse,
    );
  });

  test(
    'schema 18 keeps the whole ledger when the connection enforces foreign keys',
    () async {
      // occurrence_events cascades from medication_occurrences and
      // care_event_details references an event: a rebuild that dropped the
      // parent with enforcement on would silently erase the dose history.
      final schema = await verifier.schemaAt(17);
      final raw = schema.rawDatabase;
      _seedCare(raw, 17);
      raw.execute('PRAGMA foreign_keys = ON');

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);
      await _migrateAndValidate(verifier, db, 17);

      Future<int> count(String table) async =>
          (await db
                  .customSelect('SELECT count(*) AS n FROM $table')
                  .getSingle())
              .read<int>('n');
      expect(await count('medication_occurrences'), 2);
      expect(await count('occurrence_events'), 1);
      expect(await count('care_event_details'), 1);
    },
  );

  for (var from = 1; from < AppDatabase.supportedSchemaVersion; from++) {
    test('migrates a v$from store to v18 keeping its data', () async {
      final schema = await verifier.schemaAt(from);
      final raw = schema.rawDatabase;
      _seedCare(raw, from);
      final seeded = _careSummary(raw);
      // The fixture's care detail names a workspace and author it never
      // creates, so some references dangle before the upgrade; the rebuild
      // must neither add nor hide any.
      final danglingBefore = raw.select('PRAGMA foreign_key_check').length;
      expect(seeded.pills, 2);

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);
      await _migrateAndValidate(verifier, db, from);

      if (from >= 4) {
        final sync = await db
            .customSelect(
              'SELECT c.last_completed_cursor AS c, r.next_cursor AS n '
              'FROM sync_component_states c, sync_staging_runs r',
            )
            .getSingle();
        expect(sync.read<String>('c'), 'cursor-42');
        expect(sync.read<String>('n'), 'cursor-43');
      }

      if (from >= 4) {
        // Schema 17 rebuilds pending_operations to admit `discarded`; the
        // unsent change survives and the new terminal state is accepted.
        final op = await db
            .customSelect(
              "SELECT state FROM pending_operations WHERE id = 'op-fixture'",
            )
            .getSingle();
        expect(op.read<String>('state'), 'blocked');
        await db.customStatement(
          "UPDATE pending_operations SET state = 'discarded' "
          "WHERE id = 'op-fixture'",
        );
        final discarded = await db
            .customSelect(
              "SELECT state FROM pending_operations WHERE id = 'op-fixture'",
            )
            .getSingle();
        expect(discarded.read<String>('state'), 'discarded');
      }

      if (from >= 4) {
        // Schema 18 rebuilds the occurrence ledger to admit `missed`/`miss`:
        // every parent, event and event detail survives, the cascade did not
        // fire, and the widened values are accepted (and junk still is not).
        Future<int> count(String table) async =>
            (await db
                    .customSelect('SELECT count(*) AS n FROM $table')
                    .getSingle())
                .read<int>('n');
        expect(await count('medication_occurrences'), 2);
        expect(await count('occurrence_events'), 1);
        if (from >= 9) expect(await count('care_event_details'), 1);
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          hasLength(danglingBefore),
        );
        await db.customStatement(
          "UPDATE medication_occurrences SET state = 'missed' "
          "WHERE id = 'occurrence-2'",
        );
        await db.customStatement(
          "INSERT INTO occurrence_events (id, user_id, occurrence_id, "
          "command_id, action, from_state, to_state, origin, base_version, "
          "result_version, recorded_at) VALUES ('event-miss', 'owner-fixture', "
          "'occurrence-2', 'command-miss', 'miss', 'pending', 'missed', "
          "'native', 0, 1, 0)",
        );
        await expectLater(
          db.customStatement(
            "UPDATE medication_occurrences SET state = 'lost' "
            "WHERE id = 'occurrence-2'",
          ),
          throwsA(anything),
        );
        await db.customStatement(
          "UPDATE medication_occurrences SET state = 'pending' "
          "WHERE id = 'occurrence-2'",
        );
        await db.customStatement(
          "DELETE FROM occurrence_events WHERE id = 'event-miss'",
        );
      }

      final after = await _careSummaryAsync(db);
      expect(after.profiles, seeded.profiles);
      expect(after.pills, seeded.pills);
      expect(after.pillNames, seeded.pillNames);
      expect(after.schedules, seeded.schedules);
      expect(after.doseLogs, seeded.doseLogs);
      expect(after.doseStatuses, seeded.doseStatuses);

      if (from < 16) {
        // Schema 16 stamps every profile this phone already knew.
        final stamped = await db
            .customSelect('SELECT count(*) AS n FROM person_first_seen')
            .getSingle();
        expect(stamped.read<int>('n'), seeded.profiles);
      }
    });
  }
}

class _Care {
  const _Care(
    this.profiles,
    this.pills,
    this.pillNames,
    this.schedules,
    this.doseLogs,
    this.doseStatuses,
  );
  final int profiles;
  final int pills;
  final List<String> pillNames;
  final int schedules;
  final int doseLogs;
  final List<String> doseStatuses;
}

_Care _careSummary(sqlite.Database raw) {
  int count(String table) =>
      raw.select('SELECT count(*) AS n FROM $table').single['n'] as int;
  return _Care(
    count('profiles'),
    count('pills'),
    [
      for (final row in raw.select('SELECT name FROM pills ORDER BY id'))
        row['name'] as String,
    ],
    count('schedules'),
    count('dose_logs'),
    [
      for (final row in raw.select('SELECT status FROM dose_logs ORDER BY id'))
        row['status'] as String,
    ],
  );
}

Future<_Care> _careSummaryAsync(AppDatabase db) async {
  Future<int> count(String table) async =>
      (await db.customSelect('SELECT count(*) AS n FROM $table').getSingle())
          .read<int>('n');
  return _Care(
    await count('profiles'),
    await count('pills'),
    [
      for (final row
          in await db.customSelect('SELECT name FROM pills ORDER BY id').get())
        row.read<String>('name'),
    ],
    await count('schedules'),
    await count('dose_logs'),
    [
      for (final row
          in await db
              .customSelect('SELECT status FROM dose_logs ORDER BY id')
              .get())
        row.read<String>('status'),
    ],
  );
}

/// Inserts fictional care rows using only the columns each historical version
/// actually has: required columns without a default are filled by type.
void _seedCare(sqlite.Database raw, int version) {
  bool hasTable(String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?",
    [table],
  ).isNotEmpty;

  void insert(String table, Map<String, Object?> values) {
    final columns = <String>[];
    final args = <Object?>[];
    for (final column in raw.select('PRAGMA table_info($table)')) {
      final name = column['name'] as String;
      if (values.containsKey(name)) {
        columns.add(name);
        args.add(values[name]);
      } else if ((column['notnull'] as int) == 1 &&
          column['dflt_value'] == null) {
        columns.add(name);
        final type = (column['type'] as String).toUpperCase();
        args.add(type.contains('TEXT') ? 'fixture' : 1);
      }
    }
    raw.execute(
      'INSERT INTO $table (${columns.join(',')}) '
      'VALUES (${List.filled(columns.length, '?').join(',')})',
      args,
    );
  }

  const owner = 'owner-fixture';
  if (hasTable('users')) insert('users', {'id': owner, 'email': 'a@b.test'});
  for (final n in [1, 2]) {
    insert('profiles', {'id': 'profile-$n', 'user_id': owner, 'name': 'P$n'});
    insert('pills', {
      'id': 'pill-$n',
      'profile_id': 'profile-$n',
      'name': 'Fixture medication $n',
    });
  }
  if (hasTable('sync_component_states')) {
    // A published checkpoint and a half-fetched staged page: the v12-v14 table
    // rebuilds must retain both.
    insert('sync_component_states', {
      'user_id': owner,
      'component': 'medicationBridge',
      'contract_version': version >= 12 ? 3 : 1,
      'last_completed_cursor': 'cursor-42',
    });
    insert('sync_staging_runs', {
      'id': 'run-1',
      'user_id': owner,
      'component': 'medicationBridge',
      'contract_version': version >= 12 ? 3 : 1,
      'next_cursor': 'cursor-43',
    });
  }
  if (hasTable('pending_operations')) {
    insert('pending_operations', {
      'id': 'op-fixture',
      'user_id': owner,
      'mutation_id': 'mutation-fixture',
      'component': 'stable',
      'operation_type': 'pill.update',
      'contract_version': 2,
      'payload_json': '{}',
      'state': 'blocked',
    });
  }
  if (hasTable('medication_occurrences')) {
    // The occurrence ledger the schema 18 rebuild must keep whole: parents,
    // their cascading events, and the care detail that references an event.
    for (final n in [1, 2]) {
      insert('medication_occurrences', {
        'id': 'occurrence-$n',
        'user_id': owner,
        'occurrence_key': 'key-$n',
        'source': 'scheduled',
        'provenance': 'exact',
        'state': n == 1 ? 'taken' : 'pending',
        'state_version': n == 1 ? 1 : 0,
      });
    }
    insert('occurrence_events', {
      'id': 'event-1',
      'user_id': owner,
      'occurrence_id': 'occurrence-1',
      'command_id': 'command-1',
      'action': 'take',
      'from_state': 'pending',
      'to_state': 'taken',
      'origin': 'native',
      'base_version': 0,
      'result_version': 1,
    });
    if (hasTable('care_event_details')) {
      insert('care_event_details', {
        'event_id': 'event-1',
        'workspace_id': 'workspace-fixture',
        'command_id': 'command-1',
        'author_id': 'author-fixture',
      });
    }
  }
  insert('schedules', {
    'id': 'schedule-1',
    'pill_id': 'pill-1',
    'frequency': 'daily',
    'frequency_days': '[]',
  });
  for (final n in [1, 2]) {
    insert('dose_logs', {
      'id': 'dose-$n',
      'schedule_id': 'schedule-1',
      'status': n == 1 ? 'taken' : 'skipped',
    });
  }
}

/// The only differences a migrated store may show against the dumped schema.
///
/// * `profiles_first_seen` is a Dart-declared trigger (see
///   `AppDatabase.profilesFirstSeenTrigger`) that `drift_dev schema dump` does
///   not record, so the verifier reports it as an extra entry.
/// * Stores older than v4 predate the revision-aware tables. The upgrade step
///   creates those tables and replaces inline `server_id UNIQUE` with four
///   partial unique indexes; the six lookup indexes are then added by the
///   protected opening path (`_ensureGeneratedIndexes`), which this test does
///   not run. Both effects are pinned here so nothing else can slip through.
Future<void> _migrateAndValidate(
  SchemaVerifier verifier,
  AppDatabase db,
  int from,
) async {
  try {
    await verifier.migrateAndValidate(
      db,
      AppDatabase.supportedSchemaVersion,
      options: const ValidationOptions(validateDropped: true),
    );
  } on SchemaMismatch catch (mismatch) {
    final message = mismatch.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    final extras = RegExp(
      r'unexpected entries: ([a-z_, ]+?)(?= [a-z_]+: columns:|$)',
    ).firstMatch(message)!.group(1)!.split(', ').toSet();
    const identityTables = ['profiles', 'pills', 'schedules', 'dose_logs'];
    if (from >= 4) {
      expect(message, endsWith('unexpected entries: profiles_first_seen'));
      expect(extras, {'profiles_first_seen'});
    } else {
      expect(extras, {
        'profiles_first_seen',
        for (final table in identityTables) '${table}_server_id_unique',
      });
      for (final index in const [
        'medication_occurrences_user_planned_at',
        'occurrence_events_user_occurrence_recorded',
        'inventory_events_user_pill_recorded',
        'pending_operations_user_state_created',
        'sync_staging_runs_user_component',
        'migration_issues_user_state_created',
      ]) {
        expect(
          message,
          contains(
            'comparing $index: The actual schema does not contain anything '
            'with this name.',
          ),
        );
      }
      for (final table in identityTables) {
        expect(message, contains('$table: columns:'));
      }
      expect(
        'server_id: Not equal: `NULL UNIQUE` (expected) and `NULL` (actual)'
            .allMatches(message),
        hasLength(4),
      );
      // v1/v2 dose logs had no updated_at; the step adds it with DEFAULT 0.
      expect(
        message,
        from < 3
            ? contains(
                'updated_at: Not equal: `NOT NULL` (expected) and '
                '`NOT NULL DEFAULT 0` (actual)',
              )
            : isNot(contains('updated_at')),
      );
      expect('comparing '.allMatches(message), hasLength(6));
    }
    final triggers = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger'")
        .get();
    expect(triggers.map((row) => row.read<String>('name')), [
      'profiles_first_seen',
    ]);
  }
}
