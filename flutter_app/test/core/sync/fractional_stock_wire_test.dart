import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/inventory/pill_stock.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

class _MockDio extends Mock implements Dio {}

const _serverOccurrenceId = '30000000-0000-4000-8000-000000000011';
const _profile = '10000000-0000-4000-8000-000000000401';
const _pill = '10000000-0000-4000-8000-000000000402';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  group('administrationAmount on a take', () {
    Future<Map<String, dynamic>> sentTake({
      required bool serverHasExactStock,
      required MedicationAmount amount,
    }) async {
      final f = await CareRecordingFixture.create(
        connected: true,
        legacyStock: 10,
      );
      addTearDown(f.db.close);
      SharedPreferences.setMockInitialValues({
        LedgerModeHint.fractionalStockKey: serverHasExactStock,
      });
      await (f.db.update(
        f.db.medicationOccurrences,
      )..where((r) => r.id.equals(f.occurrence.id))).write(
        const MedicationOccurrencesCompanion(
          serverId: Value(_serverOccurrenceId),
        ),
      );
      final context = f.workspace.context;
      final scope = SyncWriteScope(
        access: f.workspace.access,
        capability: NetworkCapability(
          ownerId: context.ownerUserId,
          endpoint: context.endpoint!,
          epoch: context.networkEpoch!,
          generation: context.sessionGeneration!,
        ),
      );
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: context,
      );
      final take = await service.commit(
        await service.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
          amount: amount,
        ),
      );
      final posts = <Map<String, dynamic>>[];
      final dio = _MockDio();
      when(() => dio.post<dynamic>(any(), data: any(named: 'data'))).thenAnswer(
        (invocation) async {
          final data = Map<String, dynamic>.from(
            invocation.namedArguments[#data] as Map,
          );
          posts.add(data);
          return Response(
            data: {'commandId': data['commandId']},
            requestOptions: RequestOptions(path: '/medication/commands'),
          );
        },
      );
      final adapter = V2MedicationSyncAdapter(
        db: f.db,
        dio: dio,
        writeScope: scope,
      );
      final op = (await f.db.pendingOperationsDao.getByMutationId(
        context.ownerUserId,
        take.event.commandId,
      ))!;
      await adapter.send(op);
      expect(posts, hasLength(1));
      return posts.single;
    }

    final half = MedicationAmount.known('1/2', 'tablet');

    test('is sent to a server with exact stock', () async {
      final body = await sentTake(serverHasExactStock: true, amount: half);
      expect(body['administrationAmount'], isA<Map>());
      expect((body['administrationAmount'] as Map)['unit'], 'tablet');
    });

    test('is never sent to a server without it', () async {
      final body = await sentTake(serverHasExactStock: false, amount: half);
      expect(body.containsKey('administrationAmount'), isFalse);
    });

    test('an unknown amount is absent even with exact stock', () async {
      final body = await sentTake(
        serverHasExactStock: true,
        amount: const MedicationAmount.unknown(),
      );
      expect(body.containsKey('administrationAmount'), isFalse);
    });
  });

  group('stock on the wire', () {
    test('a pill with an exact quantity and unit keeps both', () {
      final columns = wirePillStock({
        'currentStock': 7,
        'stockQuantity': '7.5',
        'stockUnit': 'tablet',
      });
      expect(columns.stockQuantity.value, '7.5');
      expect(columns.stockUnit.value, 'tablet');
      expect(columns.currentStock.value, 7);
    });

    test('a pill without them is a plain count', () {
      final columns = wirePillStock({'currentStock': 3});
      expect(columns.currentStock.value, 3);
      expect(columns.stockQuantity.value, isNull);
      expect(columns.stockUnit.value, isNull);
    });

    test('an inventory event reads quantityDelta, else the integer', () {
      expect(wireInventoryDelta({'delta': 0, 'quantityDelta': '-0.5'}), '-0.5');
      expect(wireInventoryDelta({'delta': -1}), '-1');
      expect(
        () => wireInventoryDelta({'quantityDelta': 'x'}),
        throwsFormatException,
      );
    });

    test('the merger stores and clears the quantity and unit', () async {
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      final at = DateTime.utc(2026, 10, 12, 8);
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'u1',
          email: 'u@example.com',
          createdAt: at,
          updatedAt: at,
        ),
      );
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: _profile,
          userId: 'u1',
          name: 'P',
          createdAt: at,
          updatedAt: at,
          serverId: const Value(_profile),
          syncStatus: const Value('synced'),
        ),
      );
      final merger = StableRecordMerger(
        db,
        reviews: AccountSettlementMerger(db),
      );
      Map<String, dynamic> change(
        String revision,
        Map<String, dynamic> stock,
      ) => {
        'id': _pill,
        'profileId': _profile,
        'revision': revision,
        'name': 'Pill',
        'dosage': null,
        'notes': null,
        'color': null,
        'lowStockThreshold': null,
        'isPrn': false,
        'deletedAt': null,
        'createdAt': '2026-10-12T08:00:00.000Z',
        'updatedAt': '2026-10-13T08:00:00.000Z',
        ...stock,
      };
      await merger.mergePill(
        change('1', {
          'currentStock': 7,
          'stockQuantity': '7.5',
          'stockUnit': 'tablet',
        }),
        {_profile: _profile},
        {},
      );
      var pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.stockQuantity, '7.5');
      expect(pill.stockUnit, 'tablet');
      await merger.mergePill(change('2', {'currentStock': 3}), {
        _profile: _profile,
      }, {});
      pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.currentStock, 3);
      expect(pill.stockQuantity, isNull);
      expect(pill.stockUnit, isNull);

      // The recount mark is sent only as true; its absence clears it.
      await merger.mergePill(
        change('3', {
          'currentStock': 7,
          'stockQuantity': '7.5',
          'stockUnit': 'tablet',
          'stockNeedsRecount': true,
        }),
        {_profile: _profile},
        {},
      );
      expect((await db.pillsDao.getById(_pill))!.stockNeedsRecount, isTrue);
      await merger.mergePill(
        change('4', {
          'currentStock': 7,
          'stockQuantity': '7.5',
          'stockUnit': 'tablet',
        }),
        {_profile: _profile},
        {},
      );
      expect((await db.pillsDao.getById(_pill))!.stockNeedsRecount, isFalse);
    });
  });
}
