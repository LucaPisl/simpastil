/// Frozen version inventories. Authority tables never enter portable care.
class BackupInventory {
  static const excludedTables = <String>{
    'credential_slots',
    'installation_key_slots',
    'refresh_tokens',
    'sync_component_states',
    'workspace_device_states',
    'workspace_grants',
    'workspace_sync_checkpoints',
    'device_restore_intents',
    'effect_settlements',
    // Device-local "first seen" instants never leave this phone.
    'person_first_seen',
    // The account-settings mirror and its unsent edits are device-local; a
    // restore writes values as ordinary edits instead (see the importer).
    'account_setting_values',
    'pending_account_settings',
  };
  static const schema10SourceColumns = <String, List<String>>{
    'care_event_details': [
      'event_id',
      'workspace_id',
      'command_id',
      'author_id',
      'author_name',
      'amount_json',
      'command_json',
      'request_fingerprint',
      'local_reversal_event_id',
      'stock_outcome',
      'stock_effect_json',
    ],
    'reviewed_stock_balances': [
      'workspace_id',
      'pill_id',
      'author_id',
      'quantity_json',
      'review_revision',
      'revision',
      'updated_at',
    ],
    'dose_logs': [
      'id',
      'schedule_id',
      'scheduled_at',
      'taken_at',
      'status',
      'note',
      'created_at',
      'updated_at',
      'server_id',
      'revision',
      'sync_status',
      'last_sync_at',
      'is_deleted',
    ],
    'inventory_events': [
      'id',
      'server_id',
      'user_id',
      'pill_id',
      'command_id',
      'kind',
      'delta',
      'occurrence_event_id',
      'reverses_inventory_event_id',
      'origin',
      'provenance_json',
      'server_sequence',
      'recorded_at',
    ],
    'local_routines': [
      'routine_id',
      'revision',
      'workspace_id',
      'author_id',
      'pill_id',
      'effective_from_millis',
      'definition_json',
      'created_at',
    ],
    'medication_occurrences': [
      'id',
      'user_id',
      'server_id',
      'pill_id',
      'schedule_id',
      'occurrence_key',
      'source',
      'schedule_revision',
      'planned_local_date',
      'planned_local_time',
      'time_zone',
      'planned_at',
      'expected',
      'snapshot_version',
      'schedule_snapshot_json',
      'provenance',
      'state',
      'state_version',
      'server_sequence',
      'superseded_at',
      'superseded_by_occurrence_id',
      'created_at',
      'updated_at',
    ],
    'migration_issues': [
      'id',
      'user_id',
      'entity_type',
      'entity_id',
      'issue_code',
      'snapshot_json',
      'server_id',
      'revision',
      'resolution_state',
      'resolved_by_user_id',
      'resolved_at',
      'created_at',
      'updated_at',
    ],
    'occurrence_events': [
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
    ],
    'pending_operation_effects': [
      'id',
      'operation_id',
      'ordinal',
      'kind',
      'legacy_source_id',
      'request_fingerprint',
      'state',
      'safe_server_id',
      'safe_result_fingerprint',
      'attempted_at',
      'acknowledged_at',
    ],
    'pending_operations': [
      'id',
      'user_id',
      'mutation_id',
      'component',
      'operation_type',
      'contract_version',
      'payload_json',
      'depends_on_operation_id',
      'state',
      'attempt_count',
      'last_attempt_at',
      'safe_error_code',
      'safe_correlation_id',
      'created_at',
    ],
    'pills': [
      'id',
      'profile_id',
      'name',
      'dosage',
      'notes',
      'color',
      'current_stock',
      'low_stock_threshold',
      'is_prn',
      'created_at',
      'updated_at',
      'server_id',
      'revision',
      'sync_status',
      'last_sync_at',
      'is_deleted',
    ],
    'profiles': [
      'id',
      'user_id',
      'name',
      'avatar_emoji',
      'is_active',
      'created_at',
      'updated_at',
      'server_id',
      'revision',
      'sync_status',
      'last_sync_at',
      'is_deleted',
    ],
    'refresh_tokens': [
      'id',
      'user_id',
      'family_id',
      'expires_at',
      'revoked',
      'created_at',
      'server_id',
      'sync_status',
      'last_sync_at',
      'is_deleted',
    ],
    'device_reminder_settings': [
      'workspace_id',
      'full_details',
      'readiness_epoch',
      'test_json',
    ],
    'device_schedule_reminders': [
      'workspace_id',
      'schedule_id',
      'enabled',
      'follow_up_minutes_json',
    ],
    'schedules': [
      'id',
      'pill_id',
      'hour',
      'minute',
      'frequency',
      'frequency_days',
      'is_active',
      'created_at',
      'updated_at',
      'server_id',
      'revision',
      'sync_status',
      'last_sync_at',
      'is_deleted',
    ],
    'medication_details': [
      'pill_id',
      'package_strength',
      'form',
      'amount_json',
      'legacy_dosage_reviewed',
    ],
    'setup_drafts': [
      'id',
      'workspace_id',
      'author_id',
      'purpose',
      'step',
      'profile_id',
      'medication_id',
      'payload_json',
      'revision',
      'updated_at',
    ],
    'sync_component_states': [
      'user_id',
      'component',
      'contract_version',
      'last_completed_cursor',
      'last_full_success_at',
      'current_state',
      'diagnostic_metadata_json',
    ],
    'sync_staging_runs': [
      'id',
      'user_id',
      'component',
      'contract_version',
      'after_sequence',
      'through_sequence',
      'next_cursor',
      'page_count',
      'final_page_received',
      'started_at',
    ],
    'sync_staging_items': [
      'run_id',
      'server_sequence',
      'entity_type',
      'entity_id',
      'payload_json',
    ],
    'users': [
      'id',
      'email',
      'created_at',
      'updated_at',
      'session_generation',
      'server_id',
      'sync_status',
      'last_sync_at',
      'is_deleted',
    ],
    'care_workspaces': [
      'id',
      'owner_user_id',
      'kind',
      'singleton_key',
      'binding_state',
      'endpoint',
      'legacy_endpoint_hint',
      'current_author_id',
      'selected_profile_id',
      'view_everyone',
      'legacy_viewer_migrated',
      'created_at',
    ],
    'workspace_authors': [
      'id',
      'workspace_id',
      'display_name',
      'provenance',
      'created_at',
    ],
    'workspace_grants': [
      'workspace_id',
      'epoch',
      'is_granted',
      'session_generation',
      'network_epoch',
      'endpoint',
    ],
    'device_person_reminders': ['profile_id', 'enabled'],
    'workspace_device_states': [
      'id',
      'selected_workspace_id',
      'network_epoch',
      'network_owner_id',
      'network_endpoint',
      'network_generation',
      'network_credential_id',
      'configured_endpoint',
      'installation_epoch',
      'installation_key_id',
    ],
    'credential_slots': ['id', 'owner_id', 'endpoint', 'state', 'created_at'],
    'installation_key_slots': ['id', 'endpoint', 'state', 'created_at'],
    'workspace_sync_checkpoints': [
      'workspace_id',
      'profile_id',
      'channel',
      'cursor',
      'completed_at',
    ],
  };
  static const schema11SourceColumns = <String, List<String>>{
    ...schema10SourceColumns,
    'import_receipts': [
      'id',
      'workspace_id',
      'source_digest',
      'source_document_id',
      'source_captured_at',
      'mode',
      'selected_profile_ids_json',
      'identity_map_json',
      'applied_at',
    ],
    'import_evidence': [
      'receipt_id',
      'entity_table',
      'entity_key',
      'version',
      'ordinal',
      'source_digest',
      'payload_base64',
      'disposition',
    ],
    'import_conflicts': [
      'id',
      'receipt_id',
      'workspace_id',
      'entity_table',
      'entity_key',
      'current_digest',
      'incoming_digest',
      'created_at',
      'resolved_at',
    ],
    'device_restore_intents': [
      'id',
      'receipt_id',
      'expected_preferences_digest',
      'operations_json',
      'completed_operations_json',
      'recovery_generation',
      'state',
      'projections_completed',
      'retired_projections_json',
      'created_at',
    ],
  };

  /// Exact schema 14/15 column map; schema 15 repaired data only.
  static final schema15SourceColumns = <String, List<String>>{
    ...schema11SourceColumns,
    'schedules': [
      'id',
      'pill_id',
      'hour',
      'minute',
      'frequency',
      'frequency_days',
      'is_active',
      'created_at',
      'updated_at',
      'server_id',
      'revision',
      'sync_status',
      'last_sync_at',
      'is_deleted',
      'time_zone',
      'time_zone_status',
    ],
    'occurrence_events': [
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
      'administration_amount_json',
    ],
    'effect_settlements': [
      'effect_id',
      'workspace_id',
      'user_id',
      'issue_id',
      'resolution_command_id',
      'resolution',
      'disposition',
      'request_fingerprint',
      'resolved_at',
    ],
  };

  /// Schema 16 to 18 map: schema 15 plus the device-local table.
  static final schema18SourceColumns = <String, List<String>>{
    ...schema15SourceColumns,
    'person_first_seen': ['profile_id', 'first_seen_at'],
  };

  /// Schema 19 map: schema 18 plus the schedule interval and window columns.
  /// Older documents simply lack them; a restore keeps them null.
  static final schema19SourceColumns = <String, List<String>>{
    ...schema18SourceColumns,
    'schedules': [
      ...schema18SourceColumns['schedules']!,
      'every_days',
      'anchor_date',
      'start_date',
      'end_date',
    ],
  };

  /// Schema 20 map: schema 19 plus the medication's picked shape.
  /// Older documents simply lack it; a restore leaves it null, so the
  /// medication keeps the shape derived from its form until one is picked.
  static final schema20SourceColumns = <String, List<String>>{
    ...schema19SourceColumns,
    'pills': [...schema19SourceColumns['pills']!, 'shape'],
  };

  /// Schema 21 map: schema 20 plus the exact stock and its unit, and whether
  /// the count needs a recount (a restore from an older document keeps it
  /// false).
  /// Older documents lack them (a restore keeps them null, a plain count) and
  /// wrote each inventory change as an integer, which a restore reads as the
  /// same number in exact text.
  static final schema21SourceColumns = <String, List<String>>{
    ...schema20SourceColumns,
    'pills': [
      ...schema20SourceColumns['pills']!,
      'stock_quantity',
      'stock_unit',
      'stock_needs_recount',
    ],
  };

  /// Schema 22 map: schema 21 plus the name a pulled dose was recorded under.
  /// Older documents lack it, so a restore leaves it null (the author stays
  /// unknown, never guessed).
  static final schema22SourceColumns = <String, List<String>>{
    ...schema21SourceColumns,
    'occurrence_events': [
      ...schema21SourceColumns['occurrence_events']!,
      'recorded_by_json',
    ],
  };

  /// Schema 23 map: schema 22 plus the two excluded, device-local
  /// account-settings tables. Nothing portable changes.
  static final schema23SourceColumns = <String, List<String>>{
    ...schema22SourceColumns,
    'account_setting_values': [
      'user_id',
      'key',
      'value_json',
      'revision',
      'updated_at',
    ],
    'pending_account_settings': [
      'user_id',
      'key',
      'value_json',
      'base_revision',
      'if_absent',
      'queued_at',
    ],
  };

  /// Schema 24 map: schema 23 plus the medication's as-needed
  /// limits, expiry date and prescriber and pharmacy contacts. Older documents
  /// lack them, so a restore leaves them null (no limit, no date, no contact).
  /// The phone numbers are personal data, as in the rest of a backup.
  static final schema24SourceColumns = <String, List<String>>{
    ...schema23SourceColumns,
    'pills': [
      ...schema23SourceColumns['pills']!,
      'prn_max_per_24h',
      'prn_min_gap_minutes',
      'expires_on',
      'prescriber_name',
      'prescriber_phone',
      'pharmacy_name',
      'pharmacy_phone',
    ],
  };

  /// Current (schema 25) map: schema 24 plus the medication photo table. The
  /// JPEG travels as base64 text in `bytes_base64`; `sync_status` and
  /// `remote_sha256` are restored as written and re-judged by the next sync.
  /// A photo is personal data, as in the rest of a backup.
  static final sourceColumns = <String, List<String>>{
    ...schema24SourceColumns,
    'medication_photos': [
      'pill_id',
      'bytes_base64',
      'sha256',
      'revision',
      'sync_status',
      'remote_sha256',
    ],
  };
  static Map<String, List<String>> columnsFor(int schema) => switch (schema) {
    10 => schema10SourceColumns,
    11 => schema11SourceColumns,
    12 => schema11SourceColumns,
    13 => schema11SourceColumns,
    // Schema 15 repairs data only; its tables and columns equal schema 14.
    14 || 15 => schema15SourceColumns,
    // Schema 16 adds only the excluded, device-local person_first_seen.
    // Schema 17 only adds the 'discarded' operation state value, and schema 18
    // only widens the occurrence ledger CHECKs to admit `missed`/`miss`.
    16 || 17 || 18 => schema18SourceColumns,
    // Schema 19 adds the nullable schedule interval and window columns.
    19 => schema19SourceColumns,
    // Schema 20 adds the nullable pills.shape column.
    20 => schema20SourceColumns,
    // Schema 21 adds the nullable pills.stock_quantity and stock_unit columns
    // and writes inventory_events.delta as exact decimal text.
    21 => schema21SourceColumns,
    // Schema 22 adds the nullable occurrence_events.recorded_by_json column.
    22 => schema22SourceColumns,
    // Schema 23 adds only excluded, device-local tables.
    23 => schema23SourceColumns,
    // Schema 24 adds seven nullable pills columns (limits, expiry, contacts).
    24 => schema24SourceColumns,
    // Schema 25 adds the medication_photos table.
    25 => sourceColumns,
    _ => throw ArgumentError.value(schema, 'schema'),
  };
  static const omittedColumns = <String, Set<String>>{
    'users': {'session_generation'},
    'device_reminder_settings': {'readiness_epoch', 'test_json'},
  };
  static const primaryKeys = <String, List<String>>{
    'care_event_details': ['event_id'],
    'reviewed_stock_balances': ['workspace_id', 'pill_id'],
    'dose_logs': ['id'],
    'inventory_events': ['id'],
    'local_routines': ['routine_id', 'revision'],
    'medication_occurrences': ['id'],
    'migration_issues': ['id'],
    'occurrence_events': ['id'],
    'pending_operation_effects': ['id'],
    'pending_operations': ['id'],
    'pills': ['id'],
    'profiles': ['id'],
    'device_reminder_settings': ['workspace_id'],
    'device_schedule_reminders': ['workspace_id', 'schedule_id'],
    'schedules': ['id'],
    'medication_details': ['pill_id'],
    'medication_photos': ['pill_id'],
    'setup_drafts': ['id'],
    'sync_staging_runs': ['id'],
    'sync_staging_items': ['run_id', 'server_sequence'],
    'users': ['id'],
    'care_workspaces': ['id'],
    'workspace_authors': ['id'],
    'device_person_reminders': ['profile_id'],
    'import_receipts': ['id'],
    'import_evidence': [
      'receipt_id',
      'entity_table',
      'entity_key',
      'version',
      'ordinal',
    ],
    'import_conflicts': ['id'],
  };
  static Iterable<String> get portableTableNames => portableTableNamesFor(25);
  static Iterable<String> portableTableNamesFor(int schema) =>
      columnsFor(schema).keys.where((name) => !excludedTables.contains(name));

  static List<String> portableColumns(String table, {int schema = 25}) => [
    for (final column in columnsFor(schema)[table]!)
      if (!(omittedColumns[table]?.contains(column) ?? false)) column,
  ];

  static bool preferenceAllowed(String key) =>
      const {
        'appearance_preferences_v1',
        'app_locale',
        'app_theme_mode',
        'dynamic_color_enabled',
        'app_font_size',
        'high_contrast_enabled',
        'onboarding_dismissed',
        'simpastil_device_name',
        'selected_workspace_id',
      }.contains(key) ||
      scopedPreferencePattern.hasMatch(key);

  static final scopedPreferencePattern = RegExp(
    r'^(auto_miss_enabled|notification_sound|snooze_duration_minutes|auto_miss_delay_minutes|prn_in_stats|prn_in_widget|sibling_detection_mode)_([a-zA-Z0-9_:-]{1,128})$',
  );
  static String? preferenceOwner(String key) =>
      scopedPreferencePattern.firstMatch(key)?.group(2);
}
