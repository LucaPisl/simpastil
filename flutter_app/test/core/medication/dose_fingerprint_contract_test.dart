import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_repository.dart';

/// The bridge undo sends the fingerprint of the dose it last observed. Drift
/// stores DateTime as whole seconds while the server keeps milliseconds, so
/// both sides must agree on the whole-second form.
void main() {
  late AppDatabase db;
  late Map<String, dynamic> fixture;

  setUp(() {
    db = AppDatabase.forTesting();
    fixture =
        jsonDecode(
              File(
                '../contracts/fixtures/bridge-dose-fingerprint-v1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
  });

  tearDown(() async => db.close());

  // Reference computation of the server's whole-second canonical form.
  String reference(Map<String, dynamic> dose) {
    String whole(String iso) {
      final ms = DateTime.parse(iso).millisecondsSinceEpoch;
      return DateTime.fromMillisecondsSinceEpoch(
        ms - ms % 1000,
        isUtc: true,
      ).toIso8601String();
    }

    final canonical = <String, Object?>{
      'deletedAt': null,
      'id': dose['id'],
      'scheduleId': dose['scheduleId'],
      'scheduledAt': whole(dose['scheduledAt'] as String),
      'status': dose['status'],
      'takenAt': whole(dose['takenAt'] as String),
    };
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  test('reference computation equals the shared fixture', () {
    final dose = fixture['dose'] as Map<String, dynamic>;
    expect(reference(dose), fixture['wholeSecondFingerprint']);
  });

  test(
    'a dose with non-zero milliseconds fingerprints the same after a Drift round trip',
    () async {
      final dose = fixture['dose'] as Map<String, dynamic>;
      final now = DateTime.utc(2026, 10, 7, 5, 0);
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'u1',
          email: 'u@example.com',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'p1',
          userId: 'u1',
          name: 'P',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: 'pill1',
          profileId: 'p1',
          name: 'M',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: 'sch1',
          pillId: 'pill1',
          hour: 8,
          minute: 30,
          frequency: 'daily',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final takenAt = DateTime.parse(dose['takenAt'] as String);
      expect(takenAt.millisecond, 456);
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'dose1',
          scheduleId: 'sch1',
          scheduledAt: DateTime.parse(dose['scheduledAt'] as String),
          takenAt: Value(takenAt),
          status: dose['status'] as String,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final stored = (await db.doseLogsDao.getById('dose1'))!;
      final computed = MedicationRepository.legacyDoseFingerprint(
        stored,
        serverScheduleId: dose['scheduleId'] as String,
        serverDoseId: dose['id'] as String,
      );
      expect(computed, fixture['wholeSecondFingerprint']);
      expect(computed, reference(dose));

      // Independent of storage precision: the unrounded row yields the same.
      final exact = stored.copyWith(takenAt: Value(takenAt));
      expect(
        MedicationRepository.legacyDoseFingerprint(
          exact,
          serverScheduleId: dose['scheduleId'] as String,
          serverDoseId: dose['id'] as String,
        ),
        computed,
      );
    },
  );
}
