import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/legacy_sync_compat.dart';

import '../../helpers/care_recording_fixture.dart';

class _MockDio extends Mock implements Dio {}

// A legacy-protocol pull must not replace the phone's stock count while an
// inventory command for the pill is still unsent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CareRecordingFixture f;
  late LegacySyncCompat compat;
  late String userId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    f = await CareRecordingFixture.create(connected: true, legacyStock: 8);
    addTearDown(f.db.close);
    userId = f.workspace.context.ownerUserId;
    // Rows the server knows under their own ids, so the pull may upsert them.
    await (f.db.update(
      f.db.profiles,
    )..where((p) => p.id.equals(f.person.id))).write(
      ProfilesCompanion(
        serverId: Value(f.person.id),
        syncStatus: const Value('synced'),
      ),
    );
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      PillsCompanion(
        serverId: Value(f.pill.id),
        syncStatus: const Value('synced'),
      ),
    );
    final dio = _MockDio();
    when(() => dio.get<Map<String, dynamic>>(any())).thenAnswer((call) async {
      final path = call.positionalArguments.first as String;
      final now = DateTime.utc(2026, 9, 30).toIso8601String();
      final data = switch (path) {
        '/profiles' => {
          'profiles': [
            {
              'id': f.person.id,
              'name': f.person.name,
              'createdAt': now,
              'updatedAt': now,
            },
          ],
        },
        _ when path == '/profiles/${f.person.id}/pills' => {
          'pills': [
            {
              'id': f.pill.id,
              'name': 'Pill',
              'currentStock': 99,
              'createdAt': now,
              'updatedAt': now,
            },
          ],
        },
        _ => <String, dynamic>{},
      };
      return Response(
        data: data,
        requestOptions: RequestOptions(path: path),
      );
    });
    compat = LegacySyncCompat(
      db: f.db,
      dio: dio,
      writeScope: null,
      recordLastSync: (_, _) async {},
    );
  });

  Future<int?> stock() async =>
      (await f.db.pillsDao.getById(f.pill.id))!.currentStock;

  Future<void> inventoryOp(String state) => f.db.pendingOperationsDao.enqueue(
    PendingOperationsCompanion.insert(
      id: 'op-start',
      userId: userId,
      mutationId: 'start-1',
      component: 'medication',
      operationType: 'inventory.start',
      contractVersion: 2,
      payloadJson: jsonEncode({
        'inventoryCommand': {
          'commandId': 'start-1',
          'action': 'start',
          'pillId': f.pill.id,
          'initialStock': 10,
        },
      }),
      state: Value(state),
      createdAt: DateTime.utc(2026, 9, 30),
    ),
  );

  test('adopts the server count when no stock command is unsent', () async {
    await compat.pull(userId: userId);
    expect(await stock(), 99);
  });

  test('keeps the phone count while a stock command is unsent', () async {
    await inventoryOp('queued');
    await compat.pull(userId: userId);
    expect(await stock(), 8);
  });

  test('a conflicting stock command no longer holds the count', () async {
    await inventoryOp('conflict');
    await compat.pull(userId: userId);
    expect(await stock(), 99);
  });
}
