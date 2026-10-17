import 'package:simpastil/core/db/database.dart';

/// Freezes only an explicitly constructed disposable test database at v5.
/// Schemas 6–11 add these tables; schemas12/13 widen only sync read-version CHECKs.
/// Schema 15 changes data only (orphan-owner repair), so it adds nothing to strip.
/// Schema 16 adds the device-local person_first_seen table and its trigger.
/// Schema 17 only widens the pending_operations state CHECK (rebuilt on upgrade).
/// Schema 18 only widens the occurrence ledger state/action CHECKs (rebuilt).
/// Production opening and migration never remove workspace metadata.
Future<void> freezeLegacyV5Fixture(AppDatabase database) async {
  if (AppDatabase.supportedSchemaVersion != 18) {
    throw StateError(
      'Review the historical fixture before another schema change',
    );
  }
  final version = await database
      .customSelect('PRAGMA user_version')
      .getSingle();
  if (version.read<int>('user_version') != 18) {
    throw StateError('Expected the disposable full schema-18 fixture');
  }
  await database.transaction(() async {
    await database.customStatement('DROP TRIGGER profiles_first_seen');
    await database.customStatement('DROP TABLE person_first_seen');
    // v14 additions are deliberately removed before publishing this v5
    // fixture. The migration must add them back while upgrading the file.
    await database.customStatement('DROP TABLE effect_settlements');
    await database.customStatement(
      'ALTER TABLE schedules DROP COLUMN time_zone_status',
    );
    await database.customStatement(
      'ALTER TABLE schedules DROP COLUMN time_zone',
    );
    await database.customStatement(
      'ALTER TABLE occurrence_events DROP COLUMN administration_amount_json',
    );
    for (final table in const [
      'device_restore_intents',
      'import_conflicts',
      'import_evidence',
      'import_receipts',
      'device_schedule_reminders',
      'device_reminder_settings',
      'care_event_details',
      'reviewed_stock_balances',
      'local_routines',
      'setup_drafts',
      'medication_details',
      'workspace_sync_checkpoints',
      'workspace_device_states',
      'workspace_grants',
      'workspace_authors',
      'device_person_reminders',
      'credential_slots',
      'installation_key_slots',
      'care_workspaces',
    ]) {
      await database.customStatement('DROP TABLE $table');
    }
    await database.customStatement('PRAGMA user_version=5');
  });
}

/// Removes the v14 (and v16) additions from a disposable current-schema
/// database. Callers can then remove later tables and publish another
/// historical version.
Future<void> stripSchema14Additions(AppDatabase database) async {
  await database.customStatement('DROP TRIGGER profiles_first_seen');
  await database.customStatement('DROP TABLE person_first_seen');
  await database.customStatement('DROP TABLE effect_settlements');
  await database.customStatement(
    'ALTER TABLE schedules DROP COLUMN time_zone_status',
  );
  await database.customStatement('ALTER TABLE schedules DROP COLUMN time_zone');
  await database.customStatement(
    'ALTER TABLE occurrence_events DROP COLUMN administration_amount_json',
  );
}
