import 'package:drift/drift.dart' show Value;
import 'dart:convert';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/features/dashboard/models/history_entry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/dashboard/history_provider.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/pills/schedule_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';

class _Selection extends SelectedProfileNotifier {
  _Selection(this.id);
  final String id;
  @override
  Future<String?> build() async => id;
}

class _BeforeSecondGrant extends WorkspaceAccessRepository {
  _BeforeSecondGrant(super.database);
  int checks = 0;
  Future<void> Function()? beforeSecond;
  @override
  Future<T> withGrant<T>(
    WorkspaceContext context,
    Future<T> Function() action, {
    String? profileId,
  }) async {
    if (++checks == 2) await beforeSecond?.call();
    return super.withGrant(context, action, profileId: profileId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in [
    'selected medication',
    'enabled medications',
    'routine',
    'history',
  ]) {
    for (final scenario in ['foreign', 'revoked', 'current']) {
      final revoked = scenario == 'revoked';
      test('$kind enforces protected availability: $scenario', () async {
        final db = AppDatabase.forTesting();
        addTearDown(db.close);
        final access = WorkspaceAccessRepository(db);
        final context = await access.currentContext();
        final now = DateTime.now().toUtc();
        await db.usersDao.upsert(
          UsersCompanion.insert(
            id: 'fictional-foreign-owner',
            email: 'foreign@fictional.invalid',
            createdAt: now,
            updatedAt: now,
          ),
        );
        for (final pair in [
          ('own', context.ownerUserId),
          ('foreign', 'fictional-foreign-owner'),
        ]) {
          await db.profilesDao.upsert(
            ProfilesCompanion.insert(
              id: '${pair.$1}-person',
              userId: pair.$2,
              name: 'Fictional person',
              createdAt: now,
              updatedAt: now,
            ),
          );
          await db.pillsDao.upsert(
            PillsCompanion.insert(
              id: '${pair.$1}-medication',
              profileId: '${pair.$1}-person',
              name: 'Fictional medication',
              createdAt: now,
              updatedAt: now,
            ),
          );
          await db.schedulesDao.upsert(
            SchedulesCompanion.insert(
              id: '${pair.$1}-routine',
              pillId: '${pair.$1}-medication',
              hour: 8,
              minute: 0,
              frequency: 'daily',
              createdAt: now,
              updatedAt: now,
            ),
          );
          final day =
              '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
          await db.medicationLedgerDao.upsertOccurrence(
            MedicationOccurrencesCompanion.insert(
              id: '${pair.$1}-occurrence',
              userId: pair.$2,
              pillId: Value('${pair.$1}-medication'),
              scheduleId: Value('${pair.$1}-routine'),
              occurrenceKey: 'history-fixture:${pair.$1}',
              source: 'scheduled',
              plannedLocalDate: day,
              plannedLocalTime: const Value('08:00:00'),
              timeZone: 'UTC',
              plannedAt: Value(now),
              expected: const Value(true),
              provenance: 'exact',
              scheduleSnapshotJson: jsonEncode(
                ScheduleSnapshotV1(
                  pillName: '${pair.$1} medication',
                  dosage: null,
                  frequency: 'daily',
                  frequencyDays: null,
                  hour: 8,
                  minute: 0,
                  timeZone: 'UTC',
                  profileId: '${pair.$1}-person',
                  profileName: '${pair.$1} person',
                ).toJson(),
              ),
              state: const Value('taken'),
              stateVersion: const Value(1),
              createdAt: now,
              updatedAt: now,
            ),
          );
          await db.medicationLedgerDao.appendOccurrenceEvent(
            OccurrenceEventsCompanion.insert(
              id: '${pair.$1}-event',
              userId: pair.$2,
              occurrenceId: '${pair.$1}-occurrence',
              commandId: '${pair.$1}-command',
              action: 'take',
              fromState: 'pending',
              toState: 'taken',
              origin: 'native',
              actualAt: Value(now),
              actualTimeKnown: const Value(true),
              baseVersion: 0,
              resultVersion: 1,
              recordedAt: now,
            ),
          );
        }
        final prefix = scenario == 'foreign' ? 'foreign' : 'own';
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            workspaceAccessRepositoryProvider.overrideWithValue(access),
            workspaceContextProvider.overrideWith(
              (ref) => Stream.value(context),
            ),
            selectedProfileIdProvider.overrideWith(
              () => _Selection('$prefix-person'),
            ),
            enabledProfileIdsProvider.overrideWithValue(['$prefix-person']),
          ],
        );
        addTearDown(container.dispose);
        await container.read(workspaceContextProvider.future);
        await container.read(selectedProfileIdProvider.future);
        if (revoked) {
          await (db.update(db.workspaceGrants)
                ..where((row) => row.workspaceId.equals(context.workspaceId)))
              .write(const WorkspaceGrantsCompanion(isGranted: Value(false)));
        }
        final Future<Object?> result = switch (kind) {
          'selected medication' => container.read(
            pillsWithSchedulesProvider.future,
          ),
          'enabled medications' => container.read(
            enabledPillsWithSchedulesProvider.future,
          ),
          'routine' => container.read(
            scheduleListForPillProvider('$prefix-medication').future,
          ),
          _ => container.read(historyLogsProvider.future),
        };
        if (kind == 'history' && !revoked) {
          final entries = await result as List<HistoryEntry>;
          expect(entries.map((entry) => entry.occurrenceId), [
            'own-occurrence',
          ]);
          expect(entries.single.pillName, 'own medication');
        } else if (scenario == 'current') {
          expect(await result, hasLength(1));
        } else {
          await expectLater(result, throwsA(isA<WorkspaceAccessFailure>()));
        }
      });
    }
  }

  for (final count in [false, true]) {
    test(
      'profile child ${count ? 'count' : 'rows'} re-read after a parent move before grant check',
      () async {
        final db = AppDatabase.forTesting();
        addTearDown(db.close);
        final access = _BeforeSecondGrant(db);
        final context = await access.currentContext();
        final now = DateTime.now().toUtc();
        await db.usersDao.upsert(
          UsersCompanion.insert(
            id: 'foreign',
            email: 'foreign@fictional.invalid',
            createdAt: now,
            updatedAt: now,
          ),
        );
        for (final pair in [
          ('own', context.ownerUserId),
          ('foreign', 'foreign'),
        ]) {
          await db.profilesDao.upsert(
            ProfilesCompanion.insert(
              id: pair.$1,
              userId: pair.$2,
              name: 'Fictional person',
              createdAt: now,
              updatedAt: now,
            ),
          );
        }
        await db.pillsDao.upsert(
          PillsCompanion.insert(
            id: 'medication',
            profileId: 'own',
            name: 'Fictional medication',
            createdAt: now,
            updatedAt: now,
          ),
        );
        access.beforeSecond = () async {
          await (db.update(db.pills)
                ..where((row) => row.id.equals('medication')))
              .write(const PillsCompanion(profileId: Value('foreign')));
        };
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            workspaceAccessRepositoryProvider.overrideWithValue(access),
            workspaceContextProvider.overrideWith(
              (ref) => Stream.value(context),
            ),
          ],
        );
        addTearDown(container.dispose);
        if (count) {
          expect(
            await container.read(pillCountByProfileProvider('own').future),
            0,
          );
        } else {
          expect(
            await container.read(pillsForProfileProvider('own').future),
            isEmpty,
          );
        }
        expect(access.checks, greaterThanOrEqualTo(2));
      },
    );
  }
}
