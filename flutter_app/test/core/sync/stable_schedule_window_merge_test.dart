import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';

final _at = DateTime.utc(2026, 3, 1, 6);

void main() {
  late AppDatabase db;
  late StableRecordMerger merger;
  late Map<String, dynamic> payloads;

  setUp(() async {
    payloads =
        (jsonDecode(
                  File(
                    '../contracts/fixtures/occurrence-materializer-v3.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>)['syncSchedulePayload']
            as Map<String, dynamic>;
    db = AppDatabase.forTesting();
    merger = StableRecordMerger(db, reviews: AccountSettlementMerger(db));
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: 'u1',
        email: 'u@example.com',
        createdAt: _at,
        updatedAt: _at,
      ),
    );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: 'profile-1',
        userId: 'u1',
        name: 'P',
        createdAt: _at,
        updatedAt: _at,
        syncStatus: const Value('synced'),
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: '44444444-4444-4444-8444-444444444444',
        profileId: 'profile-1',
        name: 'Pill',
        createdAt: _at,
        updatedAt: _at,
        syncStatus: const Value('synced'),
      ),
    );
  });
  tearDown(() async => db.close());

  Future<Schedule> pull(Map<String, dynamic> item) async {
    await merger.mergeSchedule(item, {}, {});
    return (await db.schedulesDao.getById(item['id'] as String))!;
  }

  test('a pulled schedule with the window keys stores all four', () async {
    final row = await pull(
      Map<String, dynamic>.from(payloads['withWindowKeys'] as Map),
    );
    expect(row.frequency, 'interval');
    expect(row.frequencyDays, isNull);
    expect(row.everyDays, 3);
    expect(row.anchorDate, '2026-03-01');
    expect(row.startDate, isNull);
    expect(row.endDate, isNull);
  });

  test('a pulled schedule without the keys decodes them as null', () async {
    final row = await pull(
      Map<String, dynamic>.from(payloads['withoutWindowKeys'] as Map),
    );
    expect(row.frequency, 'daily');
    expect(row.everyDays, isNull);
    expect(row.anchorDate, isNull);
    expect(row.startDate, isNull);
    expect(row.endDate, isNull);
  });

  test('a later pull that clears the window clears the columns', () async {
    final id = (payloads['withWindowKeys'] as Map)['id'] as String;
    await pull(Map<String, dynamic>.from(payloads['withWindowKeys'] as Map));
    final cleared = await pull({
      ...(payloads['withoutWindowKeys'] as Map).cast<String, dynamic>(),
      'revision': '2',
    });
    expect(cleared.id, id);
    expect(cleared.revision, 2);
    expect(cleared.everyDays, isNull);
    expect(cleared.anchorDate, isNull);
  });

  test(
    'a dated pulled schedule keeps its integer day list on the wire shape',
    () async {
      final row = await pull({
        ...(payloads['withoutWindowKeys'] as Map).cast<String, dynamic>(),
        'frequency': 'custom',
        'frequencyDays': [1, 3],
        'startDate': '2026-06-01',
        'endDate': '2026-06-30',
        'everyDays': null,
        'anchorDate': null,
      });
      expect(jsonDecode(row.frequencyDays!), [1, 3]);
      expect(row.startDate, '2026-06-01');
      expect(row.endDate, '2026-06-30');
    },
  );
}
