import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz_data.initializeTimeZones);
  test(
    'actual v9 file upgrade preserves care, authorship and person reminder choices',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fictional-reminder-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/care-v9.sqlite');
      final fixture = await CareRecordingFixture.create();
      addTearDown(fixture.db.close);
      final service = CareRecordingService(
        database: fixture.db,
        access: fixture.workspace.access,
        context: fixture.workspace.context,
      );
      await service.commit(
        await service.prepareTakenNow(
          personId: fixture.person.id,
          occurrenceId: fixture.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      const retained = [
        'care_workspaces',
        'workspace_authors',
        'workspace_grants',
        'device_person_reminders',
        'local_routines',
        'medication_occurrences',
        'occurrence_events',
        'care_event_details',
      ];
      Future<Map<String, String>> read(AppDatabase database) async => {
        for (final table in retained)
          table: jsonEncode(
            (await database.customSelect('SELECT * FROM $table').get())
                .map(
                  (r) => table == 'occurrence_events'
                      ? (Map<String, Object?>.from(r.data)
                          ..remove('administration_amount_json'))
                      : r.data,
                )
                .toList(),
          ),
      };
      final before = await read(fixture.db);
      expect(AppDatabase.supportedSchemaVersion, 25);
      await fixture.db.customStatement('DROP TABLE device_restore_intents');
      await fixture.db.customStatement('DROP TABLE import_conflicts');
      await fixture.db.customStatement('DROP TABLE import_evidence');
      await fixture.db.customStatement('DROP TABLE import_receipts');
      await fixture.db.customStatement('DROP TABLE device_schedule_reminders');
      await fixture.db.customStatement('DROP TABLE device_reminder_settings');
      await fixture.db.customStatement('DROP TABLE effect_settlements');
      await fixture.db.customStatement(
        'ALTER TABLE schedules DROP COLUMN time_zone_status',
      );
      await fixture.db.customStatement(
        'ALTER TABLE schedules DROP COLUMN time_zone',
      );
      await fixture.db.customStatement(
        'ALTER TABLE occurrence_events DROP COLUMN administration_amount_json',
      );
      await fixture.db.customStatement('PRAGMA user_version=9');
      await fixture.db.customStatement('VACUUM INTO ?', [file.path]);
      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      expect(await read(upgraded), before);
      expect(
        (await upgraded.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        AppDatabase.supportedSchemaVersion,
      );
      final access = WorkspaceAccessRepository(
        upgraded,
        effectsGate: SerialProjectionEffectsGate(),
      );
      final context = await access.currentContext();
      expect(context.authorId, fixture.workspace.context.authorId);
      final preferences = await ReminderPreferencesRepository(
        database: upgraded,
        access: access,
        context: context,
      ).load();
      expect(preferences.fullDetails, isTrue);
      expect(preferences.schedules, isEmpty);
      expect(
        await upgraded.select(upgraded.deviceReminderSettings).get(),
        isEmpty,
      );
    },
  );
}
