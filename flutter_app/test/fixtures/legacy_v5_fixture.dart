import 'package:simpastil/core/db/database.dart';

/// Freezes only an explicitly constructed disposable test database at v5.
/// Schemas 6–11 add these tables; schemas12/13 widen only sync read-version CHECKs.
/// Schema 15 changes data only (orphan-owner repair), so it adds nothing to strip.
/// Schema 16 adds the device-local person_first_seen table and its trigger.
/// Schema 17 only widens the pending_operations state CHECK (rebuilt on upgrade).
/// Schema 18 only widens the occurrence ledger state/action CHECKs (rebuilt).
/// Schema 19 adds the schedule interval and date-window columns (dropped).
/// Schema 20 adds the nullable pills.shape column (dropped).
/// Schema 21 adds pills.stock_quantity and stock_unit (dropped) and rebuilds
/// inventory_events with a text delta (the rebuilt table is kept as it is).
/// Schema 22 adds occurrence_events.recorded_by_json (dropped).
/// Schema 23 adds the two account-settings tables (dropped) and widens the
/// sync component CHECK (the rebuilt table is kept as it is).
/// Schema 24 adds seven nullable pills columns for the medication extras
/// (dropped).
/// Schema 25 adds the medication_photos table (dropped).
/// Production opening and migration never remove workspace metadata.
Future<void> freezeLegacyV5Fixture(AppDatabase database) async {
  if (AppDatabase.supportedSchemaVersion != 25) {
    throw StateError(
      'Review the historical fixture before another schema change',
    );
  }
  final version = await database
      .customSelect('PRAGMA user_version')
      .getSingle();
  if (version.read<int>('user_version') != 25) {
    throw StateError('Expected the disposable full schema-25 fixture');
  }
  await database.transaction(() async {
    await database.customStatement('DROP TRIGGER profiles_first_seen');
    await database.customStatement('ALTER TABLE pills DROP COLUMN shape');
    await database.customStatement(
      'ALTER TABLE pills DROP COLUMN stock_quantity',
    );
    await database.customStatement('ALTER TABLE pills DROP COLUMN stock_unit');
    for (final column in const [
      'prn_max_per_24h',
      'prn_min_gap_minutes',
      'expires_on',
      'prescriber_name',
      'prescriber_phone',
      'pharmacy_name',
      'pharmacy_phone',
    ]) {
      await database.customStatement('ALTER TABLE pills DROP COLUMN $column');
    }
    await database.customStatement('DROP TABLE medication_photos');
    await database.customStatement('DROP TABLE person_first_seen');
    await database.customStatement('DROP TABLE account_setting_values');
    await database.customStatement('DROP TABLE pending_account_settings');
    // v14 additions are deliberately removed before publishing this v5
    // fixture. The migration must add them back while upgrading the file.
    await database.customStatement('DROP TABLE effect_settlements');
    for (final column in const [
      'every_days',
      'anchor_date',
      'start_date',
      'end_date',
    ]) {
      await database.customStatement(
        'ALTER TABLE schedules DROP COLUMN $column',
      );
    }
    await database.customStatement(
      'ALTER TABLE schedules DROP COLUMN time_zone_status',
    );
    await database.customStatement(
      'ALTER TABLE schedules DROP COLUMN time_zone',
    );
    await database.customStatement(
      'ALTER TABLE occurrence_events DROP COLUMN recorded_by_json',
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
  await database.customStatement('ALTER TABLE pills DROP COLUMN shape');
  await database.customStatement(
    'ALTER TABLE pills DROP COLUMN stock_quantity',
  );
  await database.customStatement('ALTER TABLE pills DROP COLUMN stock_unit');
  await database.customStatement('DROP TABLE person_first_seen');
  await database.customStatement('DROP TABLE effect_settlements');
  for (final column in const [
    'every_days',
    'anchor_date',
    'start_date',
    'end_date',
  ]) {
    await database.customStatement('ALTER TABLE schedules DROP COLUMN $column');
  }
  await database.customStatement(
    'ALTER TABLE schedules DROP COLUMN time_zone_status',
  );
  await database.customStatement('ALTER TABLE schedules DROP COLUMN time_zone');
  await database.customStatement(
    'ALTER TABLE occurrence_events DROP COLUMN administration_amount_json',
  );
}
