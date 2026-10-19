import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/occurrence_detail_repository.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  Future<
    ({
      CareRecordingFixture f,
      CareRecordingService service,
      OccurrenceEvent orphan,
      DateTime now,
    })
  >
  discardedOrphanWithOtherDeviceEvent({DateTime? otherActualAt}) async {
    final f = await CareRecordingFixture.create(connected: true);
    addTearDown(f.db.close);
    final now = DateTime.utc(2026, 9, 30, 9, 15);
    final owner = f.workspace.context.ownerUserId;
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => now,
    );
    final receipt = await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    final orphan = receipt.event;
    final op = await f.db.pendingOperationsDao.getByMutationId(
      owner,
      orphan.commandId,
    );
    await (f.db.update(f.db.pendingOperations)
          ..where((o) => o.id.equals(op!.id)))
        .write(const PendingOperationsCompanion(state: Value('discarded')));
    await f.db
        .into(f.db.occurrenceEvents)
        .insert(
          OccurrenceEventsCompanion.insert(
            id: 'other-device-event',
            occurrenceId: orphan.occurrenceId,
            userId: owner,
            commandId: 'other-device-command',
            action: orphan.action,
            fromState: orphan.fromState,
            toState: orphan.toState,
            baseVersion: orphan.baseVersion,
            resultVersion: orphan.resultVersion,
            origin: orphan.origin,
            serverId: const Value('other-device-server-event'),
            actualAt: Value(otherActualAt),
            actualTimeKnown: Value(otherActualAt != null),
            recordedAt: now,
          ),
        );
    return (f: f, service: service, orphan: orphan, now: now);
  }

  test(
    'the occurrence detail offers the surviving event as head and Undo',
    () async {
      final s = await discardedOrphanWithOtherDeviceEvent();
      final detail = await OccurrenceDetailRepository(
        database: s.f.db,
        access: s.f.workspace.access,
        context: s.f.workspace.context,
      ).load(s.orphan.occurrenceId);
      expect(detail.head?.event.id, 'other-device-event');
      expect(detail.canUndo, isTrue);
    },
  );

  test('Undo reads the previous facts from the surviving event, not the '
      'discarded orphan', () async {
    final taken = DateTime.utc(2026, 9, 30, 8, 5);
    final s = await discardedOrphanWithOtherDeviceEvent(otherActualAt: taken);
    final owner = s.f.workspace.context.ownerUserId;
    // A later event on top of version 1 (base version 1 -> 2).
    await s.f.db
        .into(s.f.db.occurrenceEvents)
        .insert(
          OccurrenceEventsCompanion.insert(
            id: 'skip-event',
            occurrenceId: s.orphan.occurrenceId,
            userId: owner,
            commandId: 'skip-command',
            action: 'skip',
            fromState: 'taken',
            toState: 'skipped',
            baseVersion: 1,
            resultVersion: 2,
            origin: s.orphan.origin,
            serverId: const Value('skip-server-event'),
            recordedAt: s.now,
          ),
        );
    await (s.f.db.update(s.f.db.medicationOccurrences)
          ..where((o) => o.id.equals(s.orphan.occurrenceId)))
        .write(const MedicationOccurrencesCompanion(stateVersion: Value(2)));
    final intent = await s.service.prepareUndoForEntry(
      personId: s.f.person.id,
      occurrenceId: s.orphan.occurrenceId,
      expectedStateVersion: 2,
      headEventId: 'skip-event',
    );
    expect(intent.actualAt!.isAtSameMomentAs(taken), isTrue);
    expect(intent.actualTimeKnown, isTrue);
  });

  test(
    'an unsent event of a discarded command does not compete for the head',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final now = DateTime.utc(2026, 9, 30, 9, 15);
      final owner = f.workspace.context.ownerUserId;
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => now,
      );
      final receipt = await service.commit(
        await service.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      final orphan = receipt.event;
      final op = await f.db.pendingOperationsDao.getByMutationId(
        owner,
        orphan.commandId,
      );
      expect(op, isNotNull);
      await (f.db.update(f.db.pendingOperations)
            ..where((o) => o.id.equals(op!.id)))
          .write(const PendingOperationsCompanion(state: Value('discarded')));
      // Another device took the same dose: its event also holds version 1.
      await f.db
          .into(f.db.occurrenceEvents)
          .insert(
            OccurrenceEventsCompanion.insert(
              id: 'other-device-event',
              occurrenceId: orphan.occurrenceId,
              userId: owner,
              commandId: 'other-device-command',
              action: orphan.action,
              fromState: orphan.fromState,
              toState: orphan.toState,
              baseVersion: orphan.baseVersion,
              resultVersion: orphan.resultVersion,
              origin: orphan.origin,
              serverId: const Value('other-device-server-event'),
              recordedAt: now,
            ),
          );

      final view = await CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => now,
      ).load(localDate: '2026-09-30', personId: f.person.id);
      expect(view.entries.single.head?.id, 'other-device-event');
    },
  );
}
