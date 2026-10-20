import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/isolate.dart';
import 'package:drift/native.dart' as drift_native;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simpastil_storage/simpastil_storage.dart';
import 'package:uuid/uuid.dart';

import 'daos/dose_logs_dao.dart';
import 'daos/medication_ledger_dao.dart';
import 'daos/migration_issues_dao.dart';
import 'daos/pills_dao.dart';
import 'daos/pending_operations_dao.dart';
import 'daos/profiles_dao.dart';
import 'daos/schedules_dao.dart';
import 'daos/sync_state_dao.dart';
import 'daos/users_dao.dart';
import 'reopenable_lazy_database.dart';
import 'tables/dose_logs_table.dart';
import 'tables/inventory_events_table.dart';
import 'tables/medication_occurrences_table.dart';
import 'tables/migration_issues_table.dart';
import 'tables/occurrence_events_table.dart';
import 'tables/person_first_seen_table.dart';
import 'tables/pills_table.dart';
import 'tables/pending_operation_effects_table.dart';
import 'tables/pending_operations_table.dart';
import 'tables/profiles_table.dart';
import 'tables/refresh_tokens_table.dart';
import 'tables/schedules_table.dart';
import 'tables/sync_component_state_table.dart';
import 'tables/sync_staging_tables.dart';
import 'tables/users_table.dart';
import 'tables/workspace_tables.dart';
import 'tables/setup_tables.dart';
import 'tables/local_routines_table.dart';
import 'tables/care_recording_tables.dart';
import 'tables/reminder_tables.dart';
import 'tables/import_tables.dart';
import 'tables/effect_settlements_table.dart';
import '../storage/device_database_key_store.dart';
import '../storage/protected_database.dart';

part 'database.g.dart';

/// The application's single SQLite database managed by Drift.
///
/// Access via [databaseProvider] in Riverpod.
///
/// ┌─ Code generation ──────────────────────────────────────────────────────┐
/// │ This file requires generated code. After making schema changes run:    │
/// │   dart run build_runner build --delete-conflicting-outputs             │
/// └────────────────────────────────────────────────────────────────────────┘
@DriftDatabase(
  tables: [
    Users,
    RefreshTokens,
    Profiles,
    Pills,
    Schedules,
    DoseLogs,
    MedicationOccurrences,
    OccurrenceEvents,
    InventoryEvents,
    PendingOperations,
    PendingOperationEffects,
    SyncComponentStates,
    SyncStagingRuns,
    SyncStagingItems,
    MigrationIssues,
    CareWorkspaces,
    WorkspaceAuthors,
    WorkspaceGrants,
    DevicePersonReminders,
    WorkspaceDeviceStates,
    CredentialSlots,
    InstallationKeySlots,
    WorkspaceSyncCheckpoints,
    MedicationDetails,
    SetupDrafts,
    LocalRoutines,
    CareEventDetails,
    ReviewedStockBalances,
    DeviceReminderSettings,
    DeviceScheduleReminders,
    ImportReceipts,
    ImportEvidence,
    ImportConflicts,
    DeviceRestoreIntents,
    EffectSettlements,
    PersonFirstSeen,
  ],
  daos: [
    UsersDao,
    ProfilesDao,
    PillsDao,
    SchedulesDao,
    DoseLogsDao,
    MedicationLedgerDao,
    PendingOperationsDao,
    SyncStateDao,
    MigrationIssuesDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  static const supportedSchemaVersion = 18;
  AppDatabase([QueryExecutor? executor])
    : _protectedOpening = executor == null,
      super(executor ?? _openConnection());
  final bool _protectedOpening;

  /// Stamps [personFirstSeen] whenever a profile row is first inserted, so
  /// local creates, sync pulls, imports and restores need no extra code.
  /// An `ON CONFLICT DO UPDATE` upsert that takes the update path fires no
  /// INSERT trigger, and `INSERT OR IGNORE` never overwrites an existing stamp.
  static final profilesFirstSeenTrigger = Trigger(
    'CREATE TRIGGER IF NOT EXISTS profiles_first_seen '
        'AFTER INSERT ON profiles BEGIN '
        'INSERT OR IGNORE INTO person_first_seen (profile_id, first_seen_at) '
        "VALUES (NEW.id, CAST(strftime('%s', 'now') AS INTEGER)); "
        'END',
    'profiles_first_seen',
  );

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    ...super.allSchemaEntities,
    profilesFirstSeenTrigger,
  ];

  /// In-memory database for unit tests. Uses [NativeDatabase.memory()].
  AppDatabase.forTesting()
    : _protectedOpening = false,
      super(drift_native.NativeDatabase.memory());

  /// Bump this when the schema changes and provide a [MigrationStrategy].
  @override
  int get schemaVersion => supportedSchemaVersion;

  /// Refreshes subscribed reads after a separate background engine commits.
  /// Drift notifications belong to each connection, so resuming the foreground
  /// must reload both care facts and the authority used to expose those facts.
  /// This only invalidates reads; it does not change any stored data.
  void refreshExternalChanges() => markTablesUpdated(allTables);

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(pills, pills.currentStock);
        await m.addColumn(pills, pills.lowStockThreshold);
      }
      if (from < 3) {
        await m.addColumn(pills, pills.isPrn);
        await m.addColumn(doseLogs, doseLogs.note);
      }
      if (from < 4) {
        await _addMissingDoseLogUpdatedAt();
        await m.addColumn(profiles, profiles.revision);
        await m.addColumn(pills, pills.revision);
        await m.addColumn(schedules, schedules.revision);
        await m.addColumn(doseLogs, doseLogs.revision);
        await m.addColumn(users, users.sessionGeneration);

        await m.createTable(medicationOccurrences);
        await m.createTable(occurrenceEvents);
        await m.createTable(inventoryEvents);
        await m.createTable(pendingOperations);
        await m.createTable(pendingOperationEffects);
        await m.createTable(syncComponentStates);
        await m.createTable(syncStagingRuns);
        await m.createTable(syncStagingItems);
        await m.createTable(migrationIssues);

        await _ensureUniqueServerIdentities();
        await _backfillV3State();
      }
      if (from < 5) {
        // Drift's supported complex table-rebuild migration is still marked
        // experimental; it preserves existing rows while replacing the CHECK.
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(inventoryEvents));
      }
      if (from < 6) {
        await m.createTable(careWorkspaces);
        await m.createTable(workspaceAuthors);
        await m.createTable(workspaceGrants);
        await m.createTable(devicePersonReminders);
        await m.createTable(credentialSlots);
        await m.createTable(installationKeySlots);
        await m.createTable(workspaceDeviceStates);
        await m.createTable(workspaceSyncCheckpoints);
        // A v5 owner UUID and mutable server preference prove neither origin
        // nor historical authorship. Retain the exact owner and all its work.
        for (final owner in await select(users).get()) {
          final workspaceId = _migrationIds.v4();
          await into(careWorkspaces).insert(
            CareWorkspacesCompanion.insert(
              id: workspaceId,
              ownerUserId: owner.id,
              kind: 'connected',
              bindingState: 'unresolved',
              createdAt: DateTime.now().toUtc(),
            ),
          );
          await into(
            workspaceGrants,
          ).insert(WorkspaceGrantsCompanion.insert(workspaceId: workspaceId));
        }
        await customStatement('''
          INSERT INTO device_person_reminders (profile_id, enabled)
          SELECT id, is_active FROM profiles
        ''');
        await into(
          workspaceDeviceStates,
        ).insert(WorkspaceDeviceStatesCompanion.insert(id: 'device'));
      }
      if (from < 7) {
        await m.createTable(medicationDetails);
        await m.createTable(setupDrafts);
      }
      if (from < 8) {
        await m.createTable(localRoutines);
      }
      if (from < 9) {
        await m.createTable(careEventDetails);
        await m.createTable(reviewedStockBalances);
      }
      if (from < 10) {
        await m.createTable(deviceReminderSettings);
        await m.createTable(deviceScheduleReminders);
      }
      if (from < 11) {
        await m.createTable(importReceipts);
        await m.createTable(importEvidence);
        await m.createTable(importConflicts);
        await m.createTable(deviceRestoreIntents);
      }
      if (from < 12) {
        // Replace only the bridge read-version CHECKs, retaining checkpoints,
        // staged pages, their foreign keys and the staging lookup index.
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(syncComponentStates));
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(syncStagingRuns));
      }
      if (from >= 12 && from < 13) {
        // Preserve published bridge-v3 checkpoints and staged evidence while
        // allowing the separately negotiated reviewed-occurrence read version.
        // Earlier upgrades already create/rebuild these tables at current shape.
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(syncComponentStates));
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(syncStagingRuns));
      }
      if (from < 14) {
        await m.createTable(effectSettlements);
        await m.addColumn(schedules, schedules.timeZone);
        await m.addColumn(schedules, schedules.timeZoneStatus);
        if (from >= 4) {
          // Earlier upgrades create occurrence_events at the current shape.
          await m.addColumn(
            occurrenceEvents,
            occurrenceEvents.administrationAmountJson,
          );
        }
        if (from >= 13) {
          // Retain all checkpoints and staged evidence when enabling PRN v5.
          // ignore: experimental_member_use
          await m.alterTable(TableMigration(syncComponentStates));
          // ignore: experimental_member_use
          await m.alterTable(TableMigration(syncStagingRuns));
        }
      }
      if (from < 15) {
        // Data-only repair, so stores already at 14 receive it too.
        await _repairOrphanOwners();
      }
      if (from < 16) {
        // Idempotent: stores re-opened at an older user_version already hold
        // the current shape. Backfilling with each profile's own created_at is
        // the conservative choice: it never claims the phone missed days it
        // may have seen.
        await m.createTable(personFirstSeen);
        await m.createTrigger(profilesFirstSeenTrigger);
        await customStatement(
          'INSERT OR IGNORE INTO person_first_seen (profile_id, first_seen_at) '
          'SELECT id, created_at FROM profiles',
        );
      }
      if (from >= 4 && from < 17) {
        // Adds the terminal `discarded` operation state to the CHECK while
        // keeping every row, its unique key, its index and its effects. Older
        // stores create the table at the current shape in the step above.
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(pendingOperations));
      }
      if (from >= 4 && from < 18) {
        await _widenOccurrenceStateChecks(m);
      }
    },
    beforeOpen: (details) async {
      if (_protectedOpening) await _validateStoreShape(this);
      await customStatement('PRAGMA journal_mode=WAL');
    },
  );

  /// Schema 18 admits the recorded `missed` state and `miss` action. SQLite
  /// cannot alter a CHECK, so both ledger tables are rebuilt with every row,
  /// unique key and index kept. `occurrence_events` cascades from
  /// `medication_occurrences`, so a rebuild with foreign keys enforced would
  /// delete the whole event history: the step refuses to run in that state, and
  /// verifies afterwards that no row was lost and no reference was broken.
  /// Earlier upgrades (before 4) create both tables at the current shape.
  Future<void> _widenOccurrenceStateChecks(Migrator m) async {
    Future<int> enforced() async => (await customSelect(
      'PRAGMA foreign_keys',
    ).getSingle()).read<int>('foreign_keys');
    final wasEnforced = await enforced() != 0;
    if (wasEnforced) {
      await customStatement('PRAGMA foreign_keys = OFF');
      if (await enforced() != 0) {
        throw StateError('occurrence ledger rebuild needs foreign keys off');
      }
    }
    const tables = ['medication_occurrences', 'occurrence_events'];
    final rowsBefore = {
      for (final table in tables) table: await _rowCount(table),
    };
    // Stores written before every owner row existed can already hold dangling
    // references (see _repairOrphanOwners); only a rebuild-made one is a fault.
    final danglingBefore = await _danglingReferenceCount();
    // ignore: experimental_member_use
    await m.alterTable(TableMigration(medicationOccurrences));
    // ignore: experimental_member_use
    await m.alterTable(TableMigration(occurrenceEvents));
    for (final table in tables) {
      if (await _rowCount(table) != rowsBefore[table]) {
        throw StateError('$table lost rows in the schema 18 rebuild');
      }
    }
    if (await _danglingReferenceCount() != danglingBefore) {
      throw StateError('schema 18 rebuild changed foreign key integrity');
    }
    // Drift only re-enables enforcement it switched off itself.
    if (wasEnforced) await customStatement('PRAGMA foreign_keys = ON');
  }

  Future<int> _danglingReferenceCount() async =>
      (await customSelect('PRAGMA foreign_key_check').get()).length;

  Future<int> _rowCount(String table) async => (await customSelect(
    'SELECT count(*) AS n FROM $table',
  ).getSingle()).read<int>('n');

  /// Tables whose rows are owned by an account UUID (`user_id`).
  static const _ownedRowTables = [
    'profiles',
    'pending_operations',
    'migration_issues',
    'medication_occurrences',
    'occurrence_events',
    'inventory_events',
  ];

  /// Whether any retained care row names [ownerId], whether or not a `users`
  /// row or workspace exists for it. Retained rows make an owner "populated":
  /// its origin must be reviewed before it can be adopted.
  Future<bool> ownerHasRetainedRows(String ownerId) async {
    for (final table in _ownedRowTables) {
      final rows = await customSelect(
        'SELECT 1 AS found FROM $table WHERE user_id = ? LIMIT 1',
        variables: [Variable<String>(ownerId)],
      ).get();
      if (rows.isNotEmpty) return true;
    }
    return false;
  }

  /// The shipped build never wrote `users` rows although profiles carried the
  /// server account UUID, so the v6 step created no workspace for them. Give
  /// every owner that retains care but has no workspace its `users` row and an
  /// `unresolved` connected workspace: ids stay intact, origin stays unreviewed.
  /// Idempotent; owners that already have a workspace (including `local:`) and
  /// stores without orphans are untouched.
  Future<void> _repairOrphanOwners() async {
    final owners = <String>{};
    for (final table in _ownedRowTables) {
      for (final row in await customSelect(
        'SELECT DISTINCT user_id FROM $table',
      ).get()) {
        owners.add(row.read<String>('user_id'));
      }
    }
    for (final ownerId in owners) {
      final hasWorkspace = await (select(
        careWorkspaces,
      )..where((row) => row.ownerUserId.equals(ownerId))).getSingleOrNull();
      if (hasWorkspace != null) continue;
      if (await usersDao.getById(ownerId) == null) {
        final now = DateTime.now().toUtc();
        await into(users).insert(
          UsersCompanion.insert(
            id: ownerId,
            email: '',
            createdAt: now,
            updatedAt: now,
            serverId: Value(ownerId),
            syncStatus: const Value('synced'),
          ),
        );
      }
      final workspaceId = _migrationIds.v4();
      await into(careWorkspaces).insert(
        CareWorkspacesCompanion.insert(
          id: workspaceId,
          ownerUserId: ownerId,
          kind: 'connected',
          bindingState: 'unresolved',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await into(
        workspaceGrants,
      ).insert(WorkspaceGrantsCompanion.insert(workspaceId: workspaceId));
    }
  }

  // Run once on an unexposed migration candidate after protected recovery.
  // Ordinary connection opening must not delete historical rows.
  Future<void> _removeLegacyPullDuplicates() => customStatement('''
    DELETE FROM dose_logs
    WHERE id = server_id
      AND EXISTS (
        SELECT 1 FROM dose_logs AS src
        WHERE src.schedule_id = dose_logs.schedule_id
          AND src.scheduled_at = dose_logs.scheduled_at
          AND src.id != dose_logs.id
          AND src.id != src.server_id
      )
  ''');

  /// Deletes all local data belonging to [userId] within a single transaction.
  ///
  /// SQLite `ON DELETE CASCADE` constraints mean deleting profiles cascades
  /// automatically to pills → schedules → dose_logs.
  Future<void> clearAllUserData(String userId) async {
    await transaction(() async {
      final userProfiles = await (select(
        profiles,
      )..where((t) => t.userId.equals(userId))).get();
      final profileIds = userProfiles.map((p) => p.id).toList();
      final userPills = profileIds.isEmpty
          ? <Pill>[]
          : await (select(
              pills,
            )..where((t) => t.profileId.isIn(profileIds))).get();
      final pillIds = userPills.map((p) => p.id).toList();

      if (pillIds.isNotEmpty) {
        final scheduleIds =
            await (select(schedules)..where((t) => t.pillId.isIn(pillIds)))
                .get()
                .then((rows) => rows.map((s) => s.id).toList());

        if (scheduleIds.isNotEmpty) {
          await (delete(
            doseLogs,
          )..where((t) => t.scheduleId.isIn(scheduleIds))).go();
        }
        await (delete(schedules)..where((t) => t.pillId.isIn(pillIds))).go();
        await (delete(pills)..where((t) => t.id.isIn(pillIds))).go();
      }

      await (delete(
        occurrenceEvents,
      )..where((t) => t.userId.equals(userId))).go();
      await (delete(
        inventoryEvents,
      )..where((t) => t.userId.equals(userId))).go();
      await (delete(
        medicationOccurrences,
      )..where((t) => t.userId.equals(userId))).go();
      await (delete(
        pendingOperations,
      )..where((t) => t.userId.equals(userId))).go();
      await (delete(
        syncStagingRuns,
      )..where((t) => t.userId.equals(userId))).go();
      await (delete(
        syncComponentStates,
      )..where((t) => t.userId.equals(userId))).go();
      await (delete(
        migrationIssues,
      )..where((t) => t.userId.equals(userId))).go();
      if (profileIds.isNotEmpty) {
        await (delete(
          personFirstSeen,
        )..where((t) => t.profileId.isIn(profileIds))).go();
        await (delete(profiles)..where((t) => t.id.isIn(profileIds))).go();
      }
    });
  }

  static const _migrationIds = Uuid();

  Future<void> _ensureUniqueServerIdentities() async {
    const sources = <({String table, String entity, String query})>[
      (
        table: 'profiles',
        entity: 'profile',
        query:
            'SELECT x.id, x.user_id, x.sync_status FROM profiles x WHERE x.server_id = ? ORDER BY CASE WHEN x.sync_status = \'synced\' THEN 0 ELSE 1 END, x.id',
      ),
      (
        table: 'pills',
        entity: 'pill',
        query:
            'SELECT x.id, owner.user_id, x.sync_status FROM pills x JOIN profiles owner ON owner.id = x.profile_id WHERE x.server_id = ? ORDER BY CASE WHEN x.sync_status = \'synced\' THEN 0 ELSE 1 END, x.id',
      ),
      (
        table: 'schedules',
        entity: 'schedule',
        query:
            'SELECT x.id, owner.user_id, x.sync_status FROM schedules x JOIN pills pill ON pill.id = x.pill_id JOIN profiles owner ON owner.id = pill.profile_id WHERE x.server_id = ? ORDER BY CASE WHEN x.sync_status = \'synced\' THEN 0 ELSE 1 END, x.id',
      ),
      (
        table: 'dose_logs',
        entity: 'dose_log',
        query:
            'SELECT x.id, owner.user_id, x.sync_status FROM dose_logs x JOIN schedules schedule ON schedule.id = x.schedule_id JOIN pills pill ON pill.id = schedule.pill_id JOIN profiles owner ON owner.id = pill.profile_id WHERE x.server_id = ? ORDER BY CASE WHEN x.sync_status = \'synced\' THEN 0 ELSE 1 END, x.id',
      ),
    ];

    for (final source in sources) {
      final duplicates = await customSelect(
        'SELECT server_id FROM ${source.table} WHERE server_id IS NOT NULL GROUP BY server_id HAVING COUNT(*) > 1',
      ).get();
      for (final duplicate in duplicates) {
        final serverId = duplicate.read<String>('server_id');
        final rows = await customSelect(
          source.query,
          variables: [Variable<String>(serverId)],
        ).get();
        for (final row in rows.skip(1)) {
          final localId = row.read<String>('id');
          final userId = row.read<String>('user_id');
          final syncStatus = row.read<String>('sync_status');
          await _recordMigrationIssue(
            userId: userId,
            entityType: source.entity,
            entityId: localId,
            issueCode: 'duplicate_server_identity',
            serverId: serverId,
            snapshot: {
              'localId': localId,
              'serverId': serverId,
              'syncStatus': syncStatus,
            },
          );
          await customStatement(
            'UPDATE ${source.table} SET server_id = NULL WHERE id = ?',
            [localId],
          );
        }
      }
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS ${source.table}_server_id_unique ON ${source.table}(server_id) WHERE server_id IS NOT NULL',
      );
    }
  }

  Future<void> _recordMigrationIssue({
    required String userId,
    required String entityType,
    required String entityId,
    required String issueCode,
    required Map<String, Object?> snapshot,
    String? serverId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(migrationIssues).insert(
      MigrationIssuesCompanion.insert(
        id: _migrationIds.v4(),
        userId: userId,
        entityType: entityType,
        entityId: entityId,
        issueCode: issueCode,
        snapshotJson: jsonEncode(snapshot),
        serverId: Value(serverId),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Schema v1 dose logs predate `updated_at` (added without a migration
  /// step), yet the v3 backfill reads it. Add it when absent, guarded by
  /// `PRAGMA table_info`, seeding it from `created_at`. Existing rows keep
  /// their status and timestamps.
  Future<void> _addMissingDoseLogUpdatedAt() async {
    final columns = {
      for (final row in await customSelect(
        'PRAGMA table_info(dose_logs)',
      ).get())
        row.read<String>('name'),
    };
    if (columns.contains('updated_at')) return;
    await customStatement(
      'ALTER TABLE dose_logs ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
    );
    await customStatement('UPDATE dose_logs SET updated_at = created_at');
  }

  Future<void> _backfillV3State() async {
    final migratedAt = DateTime.now().toUtc();

    // Remove the known pre-guard pull ghost before materializing a second local
    // identity for the same historical log.
    await customStatement('''
      DELETE FROM dose_logs
      WHERE id = server_id
        AND EXISTS (
          SELECT 1 FROM dose_logs AS src
          WHERE src.schedule_id = dose_logs.schedule_id
            AND src.scheduled_at = dose_logs.scheduled_at
            AND src.id != dose_logs.id
            AND src.id != src.server_id
        )
    ''');

    final scheduleRows = await customSelect('''
      SELECT schedule.id, schedule.frequency, schedule.frequency_days,
             schedule.is_active, pill.is_prn, owner.user_id
      FROM schedules AS schedule
      JOIN pills AS pill ON pill.id = schedule.pill_id
      JOIN profiles AS owner ON owner.id = pill.profile_id
    ''').get();
    final invalidSchedules = <String>{};
    for (final row in scheduleRows) {
      final scheduleId = row.read<String>('id');
      final frequency = row.read<String>('frequency');
      final rawDays = row.read<String?>('frequency_days');
      List<int>? days;
      var validDays = rawDays == null;
      if (rawDays != null) {
        try {
          final decoded = jsonDecode(rawDays);
          if (decoded is List && decoded.every((value) => value is int)) {
            days = decoded.cast<int>();
            validDays =
                days.isNotEmpty &&
                days.every((day) => day >= 1 && day <= 7) &&
                days.toSet().length == days.length;
          }
        } on FormatException {
          validDays = false;
        }
      }
      final validFrequency = switch (frequency) {
        'daily' || 'prn' => rawDays == null,
        'weekly' || 'custom' => validDays,
        _ => false,
      };
      if (validFrequency) continue;

      invalidSchedules.add(scheduleId);
      final userId = row.read<String>('user_id');
      await _recordMigrationIssue(
        userId: userId,
        entityType: 'schedule',
        entityId: scheduleId,
        issueCode: 'invalid_schedule_frequency_days',
        snapshot: {
          'scheduleId': scheduleId,
          'frequency': frequency,
          'frequencyDays': rawDays,
          'isPrn': row.read<int>('is_prn') != 0,
        },
      );
      if (row.read<int>('is_active') != 0) {
        await customStatement(
          'UPDATE schedules SET is_active = 0 WHERE id = ?',
          [scheduleId],
        );
      }
    }

    final stockRows = await customSelect('''
      SELECT pill.id AS pill_id, owner.user_id, pill.current_stock
      FROM pills AS pill
      JOIN profiles AS owner ON owner.id = pill.profile_id
      WHERE pill.current_stock IS NOT NULL
    ''').get();
    for (final row in stockRows) {
      final pillId = row.read<String>('pill_id');
      await into(inventoryEvents).insert(
        InventoryEventsCompanion.insert(
          id: _migrationIds.v4(),
          userId: row.read<String>('user_id'),
          pillId: pillId,
          commandId: _migrationIds.v4(),
          kind: 'opening',
          delta: row.read<int>('current_stock'),
          origin: 'legacy_backfill',
          provenanceJson: const Value('{"source":"v3_current_stock"}'),
          recordedAt: migratedAt,
        ),
      );
    }

    final doseRows = await customSelect('''
      SELECT dose.id AS dose_id, dose.server_id, dose.schedule_id,
             dose.scheduled_at, dose.taken_at, dose.status, dose.note,
             dose.created_at, dose.updated_at, dose.sync_status,
             dose.is_deleted, schedule.pill_id, schedule.hour,
             schedule.minute, schedule.frequency, schedule.frequency_days,
             pill.is_prn, pill.name AS pill_name, pill.dosage,
             owner.id AS profile_id, owner.name AS profile_name,
             owner.user_id
      FROM dose_logs AS dose
      JOIN schedules AS schedule ON schedule.id = dose.schedule_id
      JOIN pills AS pill ON pill.id = schedule.pill_id
      JOIN profiles AS owner ON owner.id = pill.profile_id
    ''').get();
    final pendingDosePills = <String, List<String>>{};
    for (final row in doseRows) {
      final doseId = row.read<String>('dose_id');
      final scheduleId = row.read<String>('schedule_id');
      final userId = row.read<String>('user_id');
      final pillId = row.read<String>('pill_id');
      final syncStatus = row.read<String>('sync_status');
      final status = row.read<String>('status');
      final isDeleted = row.read<int>('is_deleted') != 0;

      if (syncStatus != 'synced') {
        pendingDosePills.putIfAbsent(pillId, () => []).add(doseId);
        await _persistUncertainLegacyEffect(
          userId: userId,
          sourceId: doseId,
          entityType: 'dose_log',
          operationType: isDeleted ? 'legacy_dose_delete' : 'legacy_dose_write',
          effectKind: 'dose',
          snapshot: {
            'sourceTable': 'dose_logs',
            'sourceId': doseId,
            'serverId': row.read<String?>('server_id'),
            'scheduleId': scheduleId,
            'status': status,
            'scheduledAt': row.read<int>('scheduled_at'),
            'isDeleted': isDeleted,
          },
          createdAt: migratedAt,
        );
      }
      if (isDeleted || invalidSchedules.contains(scheduleId)) continue;
      if (!const {'taken', 'skipped', 'missed'}.contains(status)) {
        await _recordMigrationIssue(
          userId: userId,
          entityType: 'dose_log',
          entityId: doseId,
          issueCode: 'unrecognized_legacy_dose_status',
          snapshot: {'doseLogId': doseId, 'status': status},
        );
        continue;
      }

      final isPrn = row.read<int>('is_prn') != 0;
      final scheduledAt = DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('scheduled_at'),
        isUtc: true,
      );
      final actualAtMillis = row.read<int?>('taken_at');
      final actualAt = actualAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(actualAtMillis, isUtc: true);
      final frequency = isPrn ? 'prn' : row.read<String>('frequency');
      List<int>? frequencyDays;
      final rawFrequencyDays = row.read<String?>('frequency_days');
      if (!isPrn && rawFrequencyDays != null) {
        try {
          final decoded = jsonDecode(rawFrequencyDays);
          if (decoded is List && decoded.every((value) => value is int)) {
            frequencyDays = decoded.cast<int>();
          }
        } on FormatException {
          frequencyDays = null;
        }
      }
      final hour = isPrn ? null : row.read<int>('hour');
      final minute = isPrn ? null : row.read<int>('minute');
      final snapshot = jsonEncode({
        'version': 1,
        'pillName': row.read<String>('pill_name'),
        'dosage': row.read<String?>('dosage'),
        'frequency': frequency,
        'frequencyDays': frequencyDays,
        'hour': hour,
        'minute': minute,
        'timeZone': 'UTC',
        'profileId': row.read<String>('profile_id'),
        'profileName': row.read<String>('profile_name'),
      });
      final occurrenceId = _migrationIds.v4();
      final eventState = switch (status) {
        'taken' => 'taken',
        'skipped' => 'skipped',
        _ => 'pending',
      };
      final createdAt = DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('created_at'),
        isUtc: true,
      );
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('updated_at'),
        isUtc: true,
      );
      final plannedLocalTime = isPrn
          ? null
          : '${hour!.toString().padLeft(2, '0')}:${minute!.toString().padLeft(2, '0')}';
      await into(medicationOccurrences).insert(
        MedicationOccurrencesCompanion.insert(
          id: occurrenceId,
          userId: userId,
          pillId: Value(pillId),
          scheduleId: Value(scheduleId),
          occurrenceKey: '${isPrn ? 'prn' : 'legacy'}:$doseId',
          source: 'legacy',
          plannedLocalDate: scheduledAt.toIso8601String().substring(0, 10),
          plannedLocalTime: Value(plannedLocalTime),
          timeZone: 'UTC',
          plannedAt: Value(isPrn ? null : scheduledAt),
          expected: Value(!isPrn),
          scheduleSnapshotJson: snapshot,
          provenance: 'legacy_estimated',
          state: Value(eventState),
          stateVersion: Value(eventState == 'pending' ? 0 : 1),
          createdAt: createdAt,
          updatedAt: updatedAt,
        ),
      );

      if (eventState == 'taken' || eventState == 'skipped') {
        await into(occurrenceEvents).insert(
          OccurrenceEventsCompanion.insert(
            id: _migrationIds.v4(),
            userId: userId,
            occurrenceId: occurrenceId,
            commandId: doseId,
            action: eventState == 'taken' ? 'take' : 'skip',
            fromState: 'pending',
            toState: eventState,
            actualAt: Value(actualAt),
            actualTimeKnown: Value(actualAt != null),
            note: Value(row.read<String?>('note')),
            origin: 'legacy_backfill',
            baseVersion: 0,
            resultVersion: 1,
            recordedAt: updatedAt,
          ),
        );
      }
    }

    final pendingStockRows = await customSelect('''
      SELECT pill.id AS pill_id, pill.server_id, pill.current_stock,
             pill.updated_at, pill.sync_status, pill.is_deleted,
             owner.user_id
      FROM pills AS pill
      JOIN profiles AS owner ON owner.id = pill.profile_id
      WHERE pill.current_stock IS NOT NULL AND pill.sync_status <> 'synced'
    ''').get();
    for (final row in pendingStockRows) {
      final pillId = row.read<String>('pill_id');
      final payload = {
        'sourceTable': 'pills',
        'sourceId': pillId,
        'serverId': row.read<String?>('server_id'),
        'currentStock': row.read<int>('current_stock'),
        'updatedAt': row.read<int>('updated_at'),
        'isDeleted': row.read<int>('is_deleted') != 0,
      };
      await _persistUncertainLegacyEffect(
        userId: row.read<String>('user_id'),
        sourceId: pillId,
        entityType: 'pill',
        operationType: 'legacy_stock_write',
        effectKind: 'inventory',
        snapshot: payload,
        createdAt: migratedAt,
      );
      final relatedDoseIds = pendingDosePills[pillId] ?? const <String>[];
      if (relatedDoseIds.isNotEmpty) {
        await _recordMigrationIssue(
          userId: row.read<String>('user_id'),
          entityType: 'pill',
          entityId: pillId,
          issueCode: 'legacy_split_pair_unproven',
          snapshot: {
            'pillId': pillId,
            'doseLogIds': relatedDoseIds,
            'stock': row.read<int>('current_stock'),
          },
        );
      }
    }
  }

  Future<void> _persistUncertainLegacyEffect({
    required String userId,
    required String sourceId,
    required String entityType,
    required String operationType,
    required String effectKind,
    required Map<String, Object?> snapshot,
    required DateTime createdAt,
  }) async {
    final payload = jsonEncode(snapshot);
    final operationId = _migrationIds.v4();
    await into(pendingOperations).insert(
      PendingOperationsCompanion.insert(
        id: operationId,
        userId: userId,
        mutationId: _migrationIds.v4(),
        component: 'medication',
        operationType: operationType,
        contractVersion: 1,
        payloadJson: payload,
        state: const Value('blocked'),
        createdAt: createdAt,
      ),
    );
    await into(pendingOperationEffects).insert(
      PendingOperationEffectsCompanion.insert(
        id: _migrationIds.v4(),
        operationId: operationId,
        ordinal: 0,
        kind: effectKind,
        legacySourceId: Value(sourceId),
        requestFingerprint: payload,
        state: const Value('uncertain'),
        attemptedAt: Value(createdAt),
      ),
    );
    await _recordMigrationIssue(
      userId: userId,
      entityType: entityType,
      entityId: sourceId,
      issueCode: 'legacy_delivery_uncertain',
      snapshot: snapshot,
    );
  }

  /// The protected care store; [onReopened] runs when it opens after a refusal.
  static QueryExecutor openProtected({void Function()? onReopened}) =>
      _openConnection(onReopened: onReopened);

  static QueryExecutor _openConnection({void Function()? onReopened}) {
    // A refused opening is retried by the next query, so "Try again" can
    // recover care without a restart. A refused coordinator has already closed
    // every gate, source and candidate handle, so the retry starts clean.
    return ReopenableLazyDatabase(() async {
      final dbFolder = await getApplicationDocumentsDirectory();
      const storage = SimpastilStorage();
      final prepared = await ProtectedStoreCoordinator(
        root: Directory(p.join(await storage.noBackupPath(), 'care')),
        legacy: File(p.join(dbFolder.path, 'simpastil.db')),
        keyStore: const SecureDeviceDatabaseKeyStore(),
        expectedSchema: supportedSchemaVersion,
        syncDirectory: storage.syncDirectory,
        validateReady: (prepared) async {
          final database = _MigrationCandidateDatabase(
            drift_native.NativeDatabase.createInBackground(
              prepared.file,
              setup: prepared.configure,
            ),
          );
          try {
            await _validateStoreShape(database);
          } finally {
            await database.close();
          }
        },
        migrateCandidate: (candidate) async {
          // Explicit executor prevents recursive entry through the startup gate.
          final database = _MigrationCandidateDatabase(
            drift_native.NativeDatabase.createInBackground(
              candidate.file,
              setup: candidate.configure,
            ),
          );
          try {
            await database.customSelect('SELECT 1').get();
            await _ensureGeneratedIndexes(database);
            await _validateStoreShape(database);
            await database._removeLegacyPullDuplicates();
          } finally {
            await database.close();
          }
        },
      ).prepare();
      // Lazy inside the worker reports failed opening through Drift's error
      // channel rather than throwing before the isolate publishes its port.
      final isolate = await DriftIsolate.spawn(
        () => LazyDatabase(
          () => drift_native.NativeDatabase.opened(prepared.openEstablished()),
        ),
      );
      try {
        return await isolate.connect(singleClientMode: true);
      } catch (_) {
        await isolate.shutdownAll();
        rethrow;
      }
    }, onReopened: onReopened);
  }

  static Future<void> _validateStoreShape(AppDatabase database) async {
    for (final table in database.allTables) {
      final name = table.actualTableName.replaceAll('"', '""');
      final columns = await database
          .customSelect('PRAGMA table_info("$name")')
          .get();
      final actual = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!actual.containsAll(table.$columns.map((column) => column.name))) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.migrationFailed,
        );
      }
    }
    for (final index in database.allSchemaEntities.whereType<Index>()) {
      final rows = await database
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
            variables: [Variable<String>(index.entityName)],
          )
          .get();
      String normalized(String value) => value
          .toLowerCase()
          .replaceAll('if not exists', '')
          .replaceAll(RegExp(r'[\s"`\[\]]'), '');
      if (rows.length != 1 ||
          normalized(rows.single.read<String>('sql')) !=
              normalized(index.createStatementsByDialect[SqlDialect.sqlite]!)) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.migrationFailed,
        );
      }
    }
    for (final trigger in database.allSchemaEntities.whereType<Trigger>()) {
      final rows = await database
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?",
            variables: [Variable<String>(trigger.entityName)],
          )
          .get();
      String normalized(String value) => value
          .toLowerCase()
          .replaceAll('if not exists', '')
          .replaceAll(RegExp(r'[\s"`\[\]]'), '');
      if (rows.length != 1 ||
          normalized(rows.single.read<String>('sql')) !=
              normalized(
                trigger.createStatementsByDialect[SqlDialect.sqlite]!,
              )) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.migrationFailed,
        );
      }
    }
    for (final table in ['profiles', 'pills', 'schedules', 'dose_logs']) {
      final indexes = await database
          .customSelect('PRAGMA index_list("$table")')
          .get();
      var valid = false;
      for (final index in indexes.where(
        (row) => row.read<int>('unique') == 1,
      )) {
        final name = index.read<String>('name');
        final escaped = name.replaceAll('"', '""');
        final columns = await database
            .customSelect('PRAGMA index_info("$escaped")')
            .get();
        if (columns.length != 1 ||
            columns.single.readNullable<String>('name') != 'server_id') {
          continue;
        }
        if (index.read<int>('partial') == 0) {
          valid = true;
          break;
        }
        if (name != '${table}_server_id_unique') continue;
        final sql = await database
            .customSelect(
              "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
              variables: [Variable<String>(name)],
            )
            .getSingle();
        String normalized(String value) =>
            value.toLowerCase().replaceAll(RegExp(r'[\s"`\[\]]'), '');
        if (normalized(sql.read<String>('sql')) ==
            normalized(
              'CREATE UNIQUE INDEX ${table}_server_id_unique ON $table(server_id) WHERE server_id IS NOT NULL',
            )) {
          valid = true;
          break;
        }
      }
      if (!valid) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.migrationFailed,
        );
      }
    }
  }

  static Future<void> _ensureGeneratedIndexes(AppDatabase database) async {
    for (final index in database.allSchemaEntities.whereType<Index>()) {
      final sql = index.createStatementsByDialect[SqlDialect.sqlite]!;
      await database.customStatement(
        sql.replaceFirst(' INDEX ', ' INDEX IF NOT EXISTS '),
      );
    }
    // Triggers are declared with IF NOT EXISTS, mirroring the indexes above.
    for (final trigger in database.allSchemaEntities.whereType<Trigger>()) {
      await database.customStatement(
        trigger.createStatementsByDialect[SqlDialect.sqlite]!,
      );
    }
  }
}

class _MigrationCandidateDatabase extends AppDatabase {
  _MigrationCandidateDatabase(super.executor);
}

/// Counts protected care openings that succeeded after a refusal in this run.
/// Readiness watches it, so a "Try again" that opens care is noticed app-wide.
final careReopenedProvider = StateProvider<int>((ref) => 0);

/// Database provider — kept alive for the full app lifetime.
///
/// Disposing the database closes the SQLite connection cleanly.
final databaseProvider = Provider<AppDatabase>(
  (ref) {
    final db = AppDatabase(
      AppDatabase.openProtected(
        onReopened: () => ref.read(careReopenedProvider.notifier).state++,
      ),
    );
    ref.onDispose(db.close);
    return db;
  },
  // Do not auto-dispose — the database must outlive all feature providers.
);
