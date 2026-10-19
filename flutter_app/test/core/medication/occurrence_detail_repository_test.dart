import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/occurrence_detail_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

OccurrenceDetailRepository _reader(CareRecordingFixture f) =>
    OccurrenceDetailRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    );

CareRecordingService _writer(CareRecordingFixture f) => CareRecordingService(
  database: f.db,
  access: f.workspace.access,
  context: f.workspace.context,
  clock: () => DateTime.utc(2026, 9, 30, 11, 17),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  test(
    'exact detail keeps planned, actual and audit facts through correction and Undo',
    () async {
      final f = await CareRecordingFixture.create(
        routineAmount: MedicationAmount.known('1/2', 'tablet'),
      );
      addTearDown(f.db.close);
      final reader = _reader(f);
      final initial = await reader.load(f.occurrence.id);
      expect(initial.canRecord, isTrue);
      expect(initial.canUndo, isFalse);
      expect(initial.audit, isEmpty);
      expect(initial.sharing, isNull);
      expect(initial.plannedAmount.quantityText, '1/2');

      final writer = _writer(f);
      final saved = await writer.commit(
        await writer.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
          amount: MedicationAmount.known('1/4', 'tablet'),
        ),
      );
      final taken = await reader.load(f.occurrence.id);
      expect(taken.head!.event.id, saved.event.id);
      expect(
        taken.head!.event.actualAt!.toUtc(),
        DateTime.utc(2026, 9, 30, 11, 17),
      );
      expect(taken.occurrence.plannedAt!.toUtc(), CareRecordingFixture.planned);
      expect(taken.head!.amount.quantityText, '1/4');
      expect(taken.head!.authorId, f.workspace.context.authorId);
      expect(taken.plannedAmount.quantityText, '1/2');
      expect(taken.sharing, CareSharingOutcome.localOnly);
      expect(taken.canUndo, isTrue);

      await writer.commit(
        await writer.prepare(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 1,
          action: MedicationAction.correct,
          targetState: MedicationState.taken,
          amount: const MedicationAmount.unknown(),
          actualAt: null,
          actualTimeKnown: false,
          note: 'Fictional correction',
        ),
      );
      final corrected = await reader.load(f.occurrence.id);
      expect(corrected.audit, hasLength(2));
      expect(corrected.head!.event.actualAt, isNull);
      expect(corrected.head!.event.actualTimeKnown, isFalse);
      expect(corrected.head!.amount.isUnknown, isTrue);
      expect(corrected.audit.first.event, taken.head!.event);
      await writer.commit(
        await writer.prepareUndoForEntry(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: corrected.occurrence.stateVersion,
          headEventId: corrected.head!.event.id,
        ),
      );
      final undone = await reader.load(f.occurrence.id);
      expect(undone.audit, hasLength(3));
      expect(undone.head!.localReversalEventId, corrected.head!.event.id);
      expect(undone.canUndo, isFalse);
      expect(undone.head!.amount.quantityText, '1/4');
    },
  );

  test(
    'retained deleted parents preserve captured history and refuse recording',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final writer = _writer(f);
      final saved = await writer.commit(
        await writer.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      await (f.db.update(
        f.db.pills,
      )..where((p) => p.id.equals(f.pill.id))).write(
        const PillsCompanion(
          name: Value('Fictional changed name'),
          isDeleted: Value(true),
        ),
      );
      await (f.db.update(
        f.db.profiles,
      )..where((p) => p.id.equals(f.person.id))).write(
        const ProfilesCompanion(
          name: Value('Fictional removed person'),
          isDeleted: Value(true),
        ),
      );
      final retained = await _reader(f).load(f.occurrence.id);
      expect(retained.personName, f.person.name);
      expect(retained.medicationName, f.pill.name);
      expect(retained.head!.event.id, saved.event.id);
      expect(retained.canRecord, isFalse);
      expect(retained.canUndo, isFalse);
      await expectLater(
        writer.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 1,
        ),
        throwsA(
          anyOf(isA<WorkspaceAccessFailure>(), isA<MedicationCommandBlocked>()),
        ),
      );
    },
  );

  test('moved medication never reattributes a retained occurrence', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    final now = DateTime.utc(2026, 9, 30);
    await f.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: 'fictional-second-person',
        userId: f.workspace.context.ownerUserId,
        name: 'Fictional other person',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(profileId: Value('fictional-second-person')),
    );
    await f.workspace.access.viewPerson(
      f.workspace.context,
      'fictional-second-person',
    );
    final retained = await _reader(f).load(f.occurrence.id);
    expect(retained.personId, f.person.id);
    expect(retained.personName, f.person.name);
    expect(retained.canRecord, isFalse);
    expect(retained.canUndo, isFalse);
  });

  test(
    'estimated history keeps unknown identity, amount and authorship',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final writer = _writer(f);
      await writer.commit(
        await writer.prepare(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
          action: MedicationAction.take,
          amount: const MedicationAmount.unknown(),
          actualAt: null,
          actualTimeKnown: false,
        ),
      );
      await f.db.delete(f.db.careEventDetails).go();
      final json =
          jsonDecode(f.occurrence.scheduleSnapshotJson) as Map<String, dynamic>;
      json['profileId'] = null;
      json['profileName'] = null;
      await (f.db.update(
        f.db.medicationOccurrences,
      )..where((o) => o.id.equals(f.occurrence.id))).write(
        MedicationOccurrencesCompanion(
          provenance: const Value('legacy_estimated'),
          scheduleSnapshotJson: Value(jsonEncode(json)),
        ),
      );
      final legacy = await _reader(f).load(f.occurrence.id);
      expect(legacy.personId, isNull);
      expect(legacy.personName, isNull);
      expect(legacy.head!.authorId, isNull);
      expect(legacy.head!.authorName, isNull);
      expect(legacy.head!.event.actualAt, isNull);
      expect(legacy.head!.amount.isUnknown, isTrue);
      expect(legacy.canRecord, isFalse);
      expect(legacy.canUndo, isFalse);
    },
  );

  test(
    'exact reader refuses a foreign owner or local snapshot origin',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final original =
          jsonDecode(f.occurrence.scheduleSnapshotJson) as Map<String, dynamic>;
      original['workspaceId'] = 'fictional-foreign-workspace';
      await (f.db.update(
        f.db.medicationOccurrences,
      )..where((o) => o.id.equals(f.occurrence.id))).write(
        MedicationOccurrencesCompanion(
          scheduleSnapshotJson: Value(jsonEncode(original)),
        ),
      );
      await expectLater(
        _reader(f).load(f.occurrence.id),
        throwsA(isA<MedicationCommandBlocked>()),
      );
      await f.db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'fictional-foreign-owner',
          email: 'fictional-foreign@example.invalid',
          createdAt: DateTime.utc(2026, 9, 30),
          updatedAt: DateTime.utc(2026, 9, 30),
        ),
      );
      await (f.db.update(
        f.db.medicationOccurrences,
      )..where((o) => o.id.equals(f.occurrence.id))).write(
        const MedicationOccurrencesCompanion(
          userId: Value('fictional-foreign-owner'),
        ),
      );
      await expectLater(
        _reader(f).load(f.occurrence.id),
        throwsA(isA<MedicationCommandBlocked>()),
      );
    },
  );

  test(
    'watch emits a grant error after sign-out instead of retained care',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final iterator = StreamIterator(_reader(f).watch(f.occurrence.id));
      addTearDown(iterator.cancel);
      expect(await iterator.moveNext(), isTrue);
      await f.workspace.access.revokeNetwork();
      await expectLater(
        iterator.moveNext(),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
    },
  );

  test('a pending dose shows the current medication name, a recorded one '
      'keeps the name it was recorded under', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    final reader = _reader(f);
    final recordedName = (await reader.load(f.occurrence.id)).medicationName;
    expect(recordedName, isNotNull);
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(name: Value('Renamed')),
    );
    expect((await reader.load(f.occurrence.id)).medicationName, 'Renamed');

    final writer = _writer(f);
    await writer.commit(
      await writer.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    expect((await reader.load(f.occurrence.id)).medicationName, recordedName);
  });
}
