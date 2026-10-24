import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:simpastil/core/inventory/stock_reading.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/features/move/move_care_service.dart';
import 'package:simpastil/features/move/move_ids.dart';
import 'package:simpastil/features/move/move_plan.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  Future<CareWorkspace> localOf(CareRecordingFixture fixture) =>
      (fixture.db.select(fixture.db.careWorkspaces)
            ..where((w) => w.id.equals(fixture.workspace.context.workspaceId)))
          .getSingle();

  test('reads people, medications, routines and recorded doses', () async {
    final fixture = await CareRecordingFixture.create();
    addTearDown(fixture.db.close);
    await fixture.recordMiss();

    final plan = await readMovePlan(
      fixture.db,
      await localOf(fixture),
      now: DateTime.utc(2026, 10, 1, 12),
    );

    expect(plan.localWorkspaceId, fixture.workspace.context.workspaceId);
    expect(plan.people.map((p) => p.id), [fixture.person.id]);
    expect(plan.medications.map((m) => m.pill.id), [fixture.pill.id]);
    expect(plan.medicationsOf(fixture.person.id), hasLength(1));
    expect(plan.schedules, hasLength(1));
    expect(plan.schedules.single.shape.frequency, 'daily');
    expect(plan.needsScheduleWindows, isFalse);
    final item = plan.history.singleWhere(
      (h) => h.occurrence.id == fixture.occurrence.id,
    );
    expect(item.finalState?.action, MedicationAction.miss);
    expect(plan.prnDoses, isEmpty);
    expect(plan.leftBehind, isEmpty);
  });

  test('an empty phone has nothing to move', () async {
    final fixture = await CareRecordingFixture.create();
    addTearDown(fixture.db.close);
    final db = fixture.db;
    await (db.delete(db.occurrenceEvents)).go();
    await (db.delete(db.medicationOccurrences)).go();
    await (db.delete(db.localRoutines)).go();
    await (db.delete(db.setupDrafts)).go();
    await (db.delete(db.pills)).go();
    await (db.delete(db.profiles)).go();

    final plan = await readMovePlan(db, await localOf(fixture));

    expect(plan.isEmpty, isTrue);
  });

  test(
    'a same-named account person is a duplicate, a moved copy is not',
    () async {
      final fixture = await CareRecordingFixture.create();
      addTearDown(fixture.db.close);
      final plan = await readMovePlan(
        fixture.db,
        await localOf(fixture),
        now: DateTime.utc(2026, 10, 1, 12),
      );
      const connected = WorkspaceContext(
        workspaceId: 'account-workspace',
        ownerUserId: '20000000-0000-4000-8000-000000000001',
        authorId: 'author',
        kind: WorkspaceKind.connected,
        accessEpoch: 1,
      );
      final now = DateTime.utc(2026, 10, 1);
      Future<void> person(String id, String name) =>
          fixture.db.profilesDao.upsert(
            ProfilesCompanion.insert(
              id: id,
              userId: connected.ownerUserId,
              name: name,
              createdAt: now,
              updatedAt: now,
            ),
          );

      await person(
        const MoveIds(
          '20000000-0000-4000-8000-000000000001',
        ).person(fixture.person.id),
        fixture.person.name,
      );
      expect(await moveDuplicates(fixture.db, plan, connected), isEmpty);

      await person('account-alex', '  fictional ALEX ');
      final duplicates = await moveDuplicates(fixture.db, plan, connected);
      expect(duplicates.keys, [fixture.person.id]);
      expect(duplicates.values.single.id, 'account-alex');
    },
  );

  test('an unknown server cannot take the move', () async {
    final fixture = await CareRecordingFixture.create();
    addTearDown(fixture.db.close);
    final plan = await readMovePlan(fixture.db, await localOf(fixture));
    expect(moveServerGap(plan, null), MoveFailureCode.serverNeedsUpdate);
  });

  group('stock the server has to be able to hold', () {
    const exactServer = ServerCapabilities(
      medicationLedgerActive: true,
      minimumClientBuild: 8,
      serverRelease: 'fixture',
      scheduleWindows: true,
      movedHistory: true,
      ledgerPrn: true,
      fractionalStock: true,
    );
    const oldServer = ServerCapabilities(
      medicationLedgerActive: true,
      minimumClientBuild: 8,
      serverRelease: 'fixture',
      scheduleWindows: true,
      movedHistory: true,
      ledgerPrn: true,
    );

    Future<MovePlan> planWith(
      CareRecordingFixture fixture,
      StockReading? stock,
    ) async {
      final plan = await readMovePlan(fixture.db, await localOf(fixture));
      final medication = plan.medications.single;
      return MovePlan(
        localWorkspaceId: plan.localWorkspaceId,
        localOwnerId: plan.localOwnerId,
        people: plan.people,
        medications: [
          MoveMedication(
            pill: medication.pill,
            detail: medication.detail,
            stock: stock,
            isPrn: medication.isPrn,
          ),
        ],
        schedules: plan.schedules,
        history: const [],
        prnDoses: const [],
        leftBehind: plan.leftBehind,
      );
    }

    StockReading reading(String wire) => StockReading(
      value: ExactStock.tryParseWire(wire)!.toDouble(),
      unit: 'tablet',
      fromBalance: false,
      exact: ExactStock.tryParseWire(wire),
    );

    test('a part tablet needs a server with exact stock', () async {
      final fixture = await CareRecordingFixture.create();
      addTearDown(fixture.db.close);
      final plan = await planWith(fixture, reading('7.5'));
      expect(
        moveServerGap(plan, oldServer),
        MoveFailureCode.stockServerNeedsUpdate,
      );
      expect(moveServerGap(plan, exactServer), isNull);
    });

    test('a whole count still moves to an older server', () async {
      final fixture = await CareRecordingFixture.create();
      addTearDown(fixture.db.close);
      final plan = await planWith(fixture, reading('8'));
      expect(moveServerGap(plan, oldServer), isNull);
    });

    test('a count with no exact decimal is recounted first', () async {
      final fixture = await CareRecordingFixture.create();
      addTearDown(fixture.db.close);
      final plan = await planWith(
        fixture,
        const StockReading(value: 2 / 3, unit: 'tablet', fromBalance: true),
      );
      expect(
        moveServerGap(plan, exactServer),
        MoveFailureCode.stockNeedsRecount,
      );
      expect(moveServerGap(plan, oldServer), MoveFailureCode.stockNeedsRecount);
    });
  });
}
