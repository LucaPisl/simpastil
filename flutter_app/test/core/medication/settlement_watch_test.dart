import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/occurrence_detail_repository.dart';

import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Today and details react to reviewed disposition without rewriting care',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final writer = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final receipt = await writer.commit(
        await writer.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      final op = (await f.db.pendingOperationsDao.getByMutationId(
        f.workspace.context.ownerUserId,
        receipt.event.commandId,
      ))!;
      await (f.db.update(f.db.pendingOperations)
            ..where((o) => o.id.equals(op.id)))
          .write(const PendingOperationsCompanion(state: Value('blocked')));
      final initialDay = Completer<void>();
      final initialDetail = Completer<void>();
      final reviewedDay = Completer<void>();
      final reviewedDetail = Completer<void>();
      void observe(
        CareSharingOutcome? sharing,
        Completer<void> initial,
        Completer<void> reviewed,
      ) {
        if (sharing == CareSharingOutcome.uncertain && !initial.isCompleted) {
          initial.complete();
        }
        if (sharing == CareSharingOutcome.reconciled && !reviewed.isCompleted) {
          reviewed.complete();
        }
      }

      final day =
          CareDayRepository(
            database: f.db,
            access: f.workspace.access,
            context: f.workspace.context,
          ).watch(localDate: '2026-09-30').listen((day) {
            observe(day.entries.single.sharing, initialDay, reviewedDay);
          });
      final detail =
          OccurrenceDetailRepository(
            database: f.db,
            access: f.workspace.access,
            context: f.workspace.context,
          ).watch(f.occurrence.id).listen((detail) {
            observe(detail.sharing, initialDetail, reviewedDetail);
          });
      addTearDown(day.cancel);
      addTearDown(detail.cancel);
      await Future.wait([
        initialDay.future,
        initialDetail.future,
      ]).timeout(const Duration(seconds: 2));
      final effects = await f.db.pendingOperationsDao.getEffects(op.id);
      expect(effects, isNotEmpty);
      await f.db.transaction(() async {
        for (final effect in effects) {
          await f.db
              .into(f.db.effectSettlements)
              .insert(
                EffectSettlementsCompanion.insert(
                  effectId: effect.id,
                  workspaceId: f.workspace.context.workspaceId,
                  userId: op.userId,
                  issueId: 'fictional-review-${effect.ordinal}',
                  resolutionCommandId: 'fictional-resolution-${effect.ordinal}',
                  resolution: 'keep_server_state',
                  disposition: 'kept_server_state',
                  requestFingerprint: effect.requestFingerprint,
                  resolvedAt: DateTime.utc(2026, 10, 6),
                ),
              );
        }
      });
      await Future.wait([
        reviewedDay.future,
        reviewedDetail.future,
      ]).timeout(const Duration(seconds: 2));
      expect(
        (await f.db.pendingOperationsDao.getById(op.id))!.state,
        'blocked',
      );
      expect(await f.db.pendingOperationsDao.getEffects(op.id), effects);
      expect(
        await f.db.medicationLedgerDao.getOccurrenceById(f.occurrence.id),
        receipt.current,
      );
    },
  );
}
