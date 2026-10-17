import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/storage/recorded_by_preference.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

const _take = '30000000-0000-4000-8000-000000000001';
const _undo = '30000000-0000-4000-8000-000000000002';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  group('chooseRecordedByName', () {
    String? pick(
      RecordedBySetting s, {
      String? primary,
      String? person,
      String? author,
    }) => chooseRecordedByName(
      setting: s,
      primaryProfileName: primary,
      personTakingItName: person,
      authorDisplayName: author,
    );

    test('primary profile is the default and wins when named', () {
      expect(
        pick(const RecordedBySetting(), primary: 'Pat', person: 'Sam'),
        'Pat',
      );
    });
    test('custom uses the trimmed typed name', () {
      expect(
        pick(
          const RecordedBySetting(
            mode: RecordedByMode.custom,
            customName: '  Nurse Kim ',
          ),
          primary: 'Pat',
        ),
        'Nurse Kim',
      );
    });
    test('person taking it uses the patient', () {
      expect(
        pick(
          const RecordedBySetting(mode: RecordedByMode.personTakingIt),
          primary: 'Pat',
          person: 'Sam',
        ),
        'Sam',
      );
    });
    test('falls back to the author name, then null', () {
      expect(pick(const RecordedBySetting(), author: 'Dev'), 'Dev');
      expect(
        pick(
          const RecordedBySetting(mode: RecordedByMode.custom, customName: ' '),
          primary: 'Pat',
          author: 'Dev',
        ),
        'Dev',
      );
      expect(
        pick(const RecordedBySetting(mode: RecordedByMode.personTakingIt)),
        isNull,
      );
    });
    test('unknown stored mode reads as primary profile', () {
      expect(RecordedByMode.parse('future'), RecordedByMode.primaryProfile);
      expect(RecordedByMode.parse(null), RecordedByMode.primaryProfile);
    });
  });

  group('recording stamps the chosen name', () {
    MedicationRepository repo(CareRecordingFixture f) => MedicationRepository(
      f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    );

    Future<void> setPrefs(
      CareRecordingFixture f,
      RecordedByMode mode, [
      String name = '',
    ]) async {
      final id = f.workspace.context.ownerUserId;
      SharedPreferences.setMockInitialValues({
        recordedByModePreferenceKey(id): mode.name,
        recordedByNamePreferenceKey(id): name,
      });
    }

    Future<List<String?>> names(CareRecordingFixture f) async {
      final rows = await f.db.select(f.db.careEventDetails).get();
      rows.sort((a, b) => a.commandId.compareTo(b.commandId));
      return [for (final r in rows) r.authorName];
    }

    Future<void> take(CareRecordingFixture f) => repo(f).apply(
      userId: f.workspace.context.ownerUserId,
      occurrenceId: f.occurrence.id,
      action: MedicationAction.take,
      actualTimeKnown: true,
      actualAt: DateTime.utc(2026, 9, 30, 9, 15),
      commandIdOverride: _take,
    );

    test('default is the primary profile name', () async {
      SharedPreferences.setMockInitialValues({});
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      await take(f);
      expect(await names(f), ['Fictional Alex']);
    });

    test('custom name is stored', () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      await setPrefs(f, RecordedByMode.custom, 'Nurse Kim');
      await take(f);
      expect(await names(f), ['Nurse Kim']);
    });

    test('person taking it stores the patient', () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      await setPrefs(f, RecordedByMode.personTakingIt);
      await take(f);
      expect(await names(f), ['Fictional Alex']);
    });

    test('changing the setting does not rewrite an earlier record', () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      await setPrefs(f, RecordedByMode.custom, 'Nurse Kim');
      await take(f);
      await setPrefs(f, RecordedByMode.custom, 'Night Staff');
      final taken = (await f.db.medicationLedgerDao.getEventsForOccurrence(
        f.occurrence.id,
      )).single;
      await repo(f).apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.undo,
        intendedState: MedicationState.pending,
        reversesEventId: taken.id,
        actualTimeKnown: false,
        commandIdOverride: _undo,
      );
      expect(await names(f), ['Nurse Kim', 'Night Staff']);
    });
  });
}
