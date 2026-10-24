import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_amount_label.dart';
import 'package:simpastil/core/medication/occurrence_detail_repository.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

Future<MedicationAmount> _headAmount(CareRecordingFixture f) async =>
    (await OccurrenceDetailRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    ).load(f.occurrence.id)).head!.amount;

/// Records a take, then optionally drops the device-local detail row (a dose
/// taken on another device) and sets the event's synced amount.
Future<void> _setup(
  CareRecordingFixture f, {
  required bool dropDetails,
  required MedicationAmount? synced,
}) async {
  final writer = CareRecordingService(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
    clock: () => DateTime.utc(2026, 9, 30, 11, 17),
  );
  final saved = await writer.commit(
    await writer.prepareTakenNow(
      personId: f.person.id,
      occurrenceId: f.occurrence.id,
      expectedStateVersion: 0,
      amount: MedicationAmount.known('1/4', 'tablet'),
    ),
  );
  if (dropDetails) await f.db.delete(f.db.careEventDetails).go();
  await (f.db.update(
    f.db.occurrenceEvents,
  )..where((e) => e.id.equals(saved.event.id))).write(
    OccurrenceEventsCompanion(
      administrationAmountJson: Value(
        synced == null ? null : jsonEncode(synced.toJson()),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  test('without a local detail row the synced amount is shown', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    await _setup(
      f,
      dropDetails: true,
      synced: MedicationAmount.known('1/2', 'tablet'),
    );
    expect(formatMedicationAmount(await _headAmount(f)), '½ tablet');
  });

  test('no local row and no synced amount is unknown', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    await _setup(f, dropDetails: true, synced: null);
    expect((await _headAmount(f)).isUnknown, isTrue);
  });

  test('an unreadable synced amount is unknown', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    await _setup(f, dropDetails: true, synced: null);
    await f.db.customStatement(
      "UPDATE occurrence_events SET administration_amount_json = 'oops'",
    );
    expect((await _headAmount(f)).isUnknown, isTrue);
  });

  test('the local detail row wins over the synced amount', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    await _setup(
      f,
      dropDetails: false,
      synced: MedicationAmount.known('1/2', 'tablet'),
    );
    expect((await _headAmount(f)).quantityText, '1/4');
  });
}
