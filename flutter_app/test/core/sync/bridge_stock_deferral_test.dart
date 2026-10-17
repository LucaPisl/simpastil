import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_recovery_service.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/features/settings/presentation/sync_diagnostics_sheet.dart';

class _MockDio extends Mock implements Dio {}

const _userId = 'user-1';
final _now = DateTime.utc(2026, 10, 14, 8);
const _stockPayload =
    '{"inventoryCommand":{"commandId":"c","pillId":"p","initialStock":4},'
    '"localProjection":{"pillId":"pill-1"}}';

Response<Map<String, dynamic>> _capabilities({required bool ledgerActive}) =>
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(path: '/capabilities'),
      data: {
        'apiNamespace': 'v1',
        'contracts': {
          'componentSync': 2,
          'legacySplitReconciliation': 1,
          'medicationBridgeCommands': 1,
          'medicationBridgeSync': 1,
          'medicationCommands': 2,
        },
        'medicationLedgerActive': ledgerActive,
        'minimumClientBuild': 1,
        'serverRelease': 'release-test',
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _MockDio dio;
  late SyncService service;
  var ledgerActive = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ledgerActive = false;
    db = AppDatabase.forTesting();
    addTearDown(db.close);
    dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>('/capabilities'),
    ).thenAnswer((_) async => _capabilities(ledgerActive: ledgerActive));
    service = SyncService(db: db, dio: dio, isOnline: () async => true);
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: _userId,
        email: 'user@example.invalid',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
  });

  Future<void> stockOp(String id, {String state = 'queued'}) => db
      .into(db.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          id: id,
          userId: _userId,
          mutationId: 'm-$id',
          component: 'medication',
          operationType: 'medication.command',
          contractVersion: 2,
          payloadJson: _stockPayload,
          state: Value(state),
          createdAt: _now,
        ),
      );

  test('stock waiting for the ledger is not pending work in bridge mode', () {
    Future<PendingOperation> row() async {
      await stockOp('stock');
      return (await db.pendingOperationsDao.getById('stock'))!;
    }

    return row().then((op) {
      final held = SyncService.tallyOperations([op], ledgerActive: false);
      expect(held.awaitingLedger, 1);
      expect(held.queued, 0);
      expect(held.automatic, 0);
      expect(held.needsAttention, 0);
      expect(held.isSettled, isTrue);
      expect(SyncService.deferredStockOperationIds([op], ledgerActive: false), {
        'stock',
      });

      for (final known in [true, null]) {
        final normal = SyncService.tallyOperations([op], ledgerActive: known);
        expect(normal.queued, 1, reason: 'ledger active=$known');
        expect(normal.awaitingLedger, 0);
        expect(
          SyncService.deferredStockOperationIds([op], ledgerActive: known),
          isEmpty,
        );
      }
    });
  });

  test(
    'a bridge-mode sync with only deferred stock is a clean success',
    () async {
      await stockOp('stock');

      await service.flushPending(userId: _userId);

      final outcome = service.lastFlushOutcome!.forStage('medication')!;
      expect(outcome.status, SyncComponentStatus.succeeded);
      // The operation is untouched: still queued, same payload, no attempts.
      final row = (await db.pendingOperationsDao.getById('stock'))!;
      expect(row.state, 'queued');
      expect(row.payloadJson, _stockPayload);
      expect(row.attemptCount, 0);

      final counts = await service.countOperations(userId: _userId);
      expect(counts.awaitingLedger, 1);
      expect(counts.queued, 0);
      expect(counts.isSettled, isTrue);

      final status = SyncStatus(
        lastSuccessAt: _now,
        pendingCount: counts.automatic + counts.stranded,
        counts: counts,
        lastRun: service.lastFlushOutcome,
      );
      expect(syncHeadlineState(status), SyncHeadlineState.synced);
    },
  );

  test(
    'once the ledger is active the same stock is normal pending work',
    () async {
      await stockOp('stock');
      await service.flushPending(userId: _userId);
      expect((await service.countOperations(userId: _userId)).queued, 0);

      await LedgerModeHint.record(
        const CapabilitySnapshot.present(
          ServerCapabilities(
            medicationLedgerActive: true,
            minimumClientBuild: 1,
            serverRelease: 'release-test',
          ),
        ),
      );

      final counts = await service.countOperations(userId: _userId);
      expect(counts.queued, 1);
      expect(counts.awaitingLedger, 0);
      final status = SyncStatus(
        lastSuccessAt: _now,
        pendingCount: counts.automatic + counts.stranded,
        counts: counts,
      );
      expect(syncHeadlineState(status), SyncHeadlineState.partiallySynced);
    },
  );

  test(
    'the recovery screen data keeps held stock out of the problem list',
    () async {
      await stockOp('stock');
      final recovery = SyncRecoveryService(
        db: db,
        flush: (_) async {},
        pull: (_) async => true,
        write: <T>(_, action) => db.transaction(action),
        now: () => _now,
      );
      await LedgerModeHint.record(const CapabilitySnapshot.absent());
      expect((await recovery.diagnose(_userId)).items, hasLength(1));

      SharedPreferences.setMockInitialValues({LedgerModeHint.key: false});
      final held = await recovery.diagnose(_userId);
      expect(held.items, isEmpty);
      expect(held.counts.awaitingLedger, 1);

      SharedPreferences.setMockInitialValues({LedgerModeHint.key: true});
      final active = await recovery.diagnose(_userId);
      expect(active.items, hasLength(1));
      expect(active.counts.awaitingLedger, 0);
    },
  );

  test('stock stranded behind a stuck change still needs a person', () async {
    await db
        .into(db.pendingOperations)
        .insert(
          PendingOperationsCompanion.insert(
            id: 'create',
            userId: _userId,
            mutationId: 'm-create',
            component: 'stable',
            operationType: 'pill.create',
            contractVersion: 2,
            payloadJson: '{"entityType":"pill","entityLocalId":"pill-1"}',
            state: const Value('blocked'),
            createdAt: _now,
          ),
        );
    await stockOp('stock');
    final ops = await db.pendingOperationsDao.getUnsettledForUser(_userId);

    final counts = SyncService.tallyOperations(ops, ledgerActive: false);
    expect(counts.stranded, 1);
    expect(counts.awaitingLedger, 0);
  });
}
