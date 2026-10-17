import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/doses/auto_miss_sweeper.dart';
import 'package:simpastil/core/medication/auto_miss_discard.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/sync/protected_background_sync.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  final planned = CareRecordingFixture.planned;
  DateTime after(Duration d) => planned.add(d);

  group('autoMissWindow', () {
    final now = DateTime.utc(2026, 10, 10, 12);

    test('waits out the delay and honours the enable time', () {
      final window = autoMissWindow(
        now: now,
        delay: const Duration(minutes: 15),
        since: DateTime.utc(2026, 10, 9),
      )!;
      expect(window.to, DateTime.utc(2026, 10, 10, 11, 45));
      expect(window.from, DateTime.utc(2026, 10, 9));
    });

    test('never looks back more than seven days', () {
      final window = autoMissWindow(
        now: now,
        delay: const Duration(minutes: 15),
        since: DateTime.utc(2026, 9, 1),
      )!;
      expect(window.from, DateTime.utc(2026, 10, 3, 12));
    });

    test('has no window while nothing is old enough', () {
      expect(
        autoMissWindow(
          now: now,
          delay: const Duration(minutes: 15),
          since: DateTime.utc(2026, 10, 10, 11, 50),
        ),
        isNull,
      );
    });
  });

  group('AutoMissSweeper', () {
    late CareRecordingFixture f;
    late String owner;
    var clock = DateTime.utc(2026, 9, 30, 9, 20);
    var supported = true;
    var supportChecks = 0;

    Future<void> configure({
      bool enabled = true,
      int? delay,
      DateTime? since,
    }) async {
      final prefs = f.workspace.preferences;
      await prefs.setBool(autoMissEnabledPreferenceKey(owner), enabled);
      if (delay != null) {
        await prefs.setInt(autoMissDelayPreferenceKey(owner), delay);
      }
      if (since != null) {
        await prefs.setInt(
          autoMissSincePreferenceKey(owner),
          since.millisecondsSinceEpoch,
        );
      }
    }

    AutoMissSweeper sweeper({Future<bool> Function()? support}) =>
        AutoMissSweeper(
          db: f.db,
          access: f.workspace.access,
          preferences: f.workspace.preferences,
          clock: () => clock,
          serverRecordsMisses:
              support ??
              () async {
                supportChecks++;
                return supported;
              },
        );

    Future<MedicationOccurrence> occurrence([String? id]) async => (await f
        .db
        .medicationLedgerDao
        .getOccurrenceById(id ?? f.occurrence.id))!;

    Future<List<PendingOperation>> medicationOps() async =>
        (await f.db.pendingOperationsDao.getForUser(
          owner,
        )).where((op) => op.component == 'medication').toList();

    Future<List<MedicationOccurrence>> addOccurrences(int count) async {
      final added = <MedicationOccurrence>[];
      for (var i = 1; i <= count; i++) {
        final companion = f.occurrence
            .toCompanion(false)
            .copyWith(
              id: Value(
                '20000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
              ),
              serverId: const Value(null),
              occurrenceKey: Value('${f.occurrence.occurrenceKey}:extra-$i'),
              plannedAt: Value(planned.add(Duration(minutes: i))),
            );
        await f.db.medicationLedgerDao.upsertOccurrence(companion);
        added.add((await occurrence(companion.id.value)));
      }
      return added;
    }

    setUp(() {
      // Past the default delay, so a test that does not choose a delay of its
      // own still starts with one overdue dose.
      clock = after(const Duration(minutes: autoMissDefaultDelayMinutes + 5));
      supported = true;
      supportChecks = 0;
    });

    group('local workspace', () {
      setUp(() async {
        f = await CareRecordingFixture.create();
        addTearDown(f.db.close);
        owner = f.workspace.context.ownerUserId;
      });

      test('records a miss once the delay has passed', () async {
        await configure(since: after(const Duration(hours: -1)));

        final result = await sweeper().sweep();

        expect(result.recorded, 1);
        expect(result.aborted, isFalse);
        final row = await occurrence();
        expect(row.state, 'missed');
        expect(row.stateVersion, 1);
        final events = await f.db.medicationLedgerDao.getEventsForOccurrence(
          row.id,
        );
        expect(events.single.action, 'miss');
        expect(events.single.fromState, 'pending');
        expect(events.single.toState, 'missed');
        expect(events.single.actualAt, isNull);
        expect(
          await medicationOps(),
          isEmpty,
          reason: 'a local workspace never syncs',
        );
        final details = await f.db.select(f.db.careEventDetails).get();
        expect(details.single.authorName, isNull);
      });

      test('uses the stored delay, one minute at a time', () async {
        await configure(since: after(const Duration(hours: -1)), delay: 30);
        clock = after(const Duration(minutes: 29, seconds: 59));
        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');

        clock = after(const Duration(minutes: 30));
        expect((await sweeper().sweep()).recorded, 1);
        expect((await occurrence()).state, 'missed');
      });

      test('waits an hour when nobody has chosen a delay', () async {
        expect(autoMissDefaultDelayMinutes, 60);
        await configure(since: after(const Duration(hours: -1)));
        expect(
          f.workspace.preferences.getInt(autoMissDelayPreferenceKey(owner)),
          isNull,
          reason: 'nobody has chosen a delay',
        );

        clock = after(const Duration(minutes: 59, seconds: 59));
        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');

        clock = after(const Duration(minutes: 60));
        expect((await sweeper().sweep()).recorded, 1);
        expect((await occurrence()).state, 'missed');
      });

      test('does nothing while the setting is off', () async {
        await configure(
          enabled: false,
          since: after(const Duration(hours: -1)),
        );

        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');
      });

      test('ignores doses due before the setting was switched on', () async {
        await configure(since: after(const Duration(minutes: 1)));

        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');
      });

      test('starts counting from now when the setting predates it', () async {
        // The earlier build only drew a label, so there is no enable time.
        await configure();

        expect((await sweeper().sweep()).recorded, 0);
        expect(
          f.workspace.preferences.getInt(autoMissSincePreferenceKey(owner)),
          clock.millisecondsSinceEpoch,
        );
        expect((await occurrence()).state, 'pending');

        // The dose that was already overdue stays alone; later ones count.
        clock = after(const Duration(days: 1, hours: 1));
        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');
      });

      test('is on without being asked, and back-fills nothing', () async {
        expect(
          f.workspace.preferences.getBool(autoMissEnabledPreferenceKey(owner)),
          isNull,
          reason: 'nobody has answered the setting',
        );

        // The dose is already overdue when the first sweep runs. It stays
        // pending, and recording starts from this moment instead.
        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');
        expect(
          f.workspace.preferences.getInt(autoMissSincePreferenceKey(owner)),
          clock.millisecondsSinceEpoch,
        );

        clock = after(const Duration(days: 1));
        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');
      });

      test('records a later miss without being asked', () async {
        // The first sweep happens before the dose is due, so it marks a
        // starting point the dose then falls after.
        clock = after(const Duration(hours: -1));
        expect((await sweeper().sweep()).recorded, 0);

        clock = after(const Duration(minutes: autoMissDefaultDelayMinutes + 5));
        expect((await sweeper().sweep()).recorded, 1);
        expect((await occurrence()).state, 'missed');
      });

      test('an explicit no is the only way to stop the sweep', () async {
        final prefs = f.workspace.preferences;
        expect(AutoMissSweeper.anyEnabled(prefs), isTrue);

        await prefs.setBool(autoMissEnabledPreferenceKey(owner), false);
        expect(AutoMissSweeper.anyEnabled(prefs), isFalse);

        await prefs.setBool(autoMissEnabledPreferenceKey(owner), true);
        expect(AutoMissSweeper.anyEnabled(prefs), isTrue);
      });

      test('never reaches back further than seven days', () async {
        await configure(since: after(const Duration(days: -30)));

        clock = after(const Duration(days: 7, minutes: 1));
        expect((await sweeper().sweep()).recorded, 0);

        clock = after(const Duration(days: 6, hours: 23));
        expect((await sweeper().sweep()).recorded, 1);
      });

      test('leaves a dose that already has an outcome alone', () async {
        await configure(since: after(const Duration(hours: -1)));
        await MedicationRepository(
          f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        ).apply(
          userId: owner,
          occurrenceId: f.occurrence.id,
          action: MedicationAction.skip,
          actualTimeKnown: false,
        );

        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'skipped');
      });

      test('does not mark a dose again after an undo', () async {
        await configure(since: after(const Duration(hours: -1)));
        await sweeper().sweep();
        final repository = MedicationRepository(
          f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        );
        final head = (await f.db.medicationLedgerDao.getEventsForOccurrence(
          f.occurrence.id,
        )).single;
        await repository.apply(
          userId: owner,
          occurrenceId: f.occurrence.id,
          action: MedicationAction.undo,
          intendedState: MedicationState.pending,
          actualTimeKnown: false,
          reversesEventId: head.id,
        );
        expect((await occurrence()).state, 'pending');
        expect((await occurrence()).stateVersion, 2);

        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');
      });

      test('does not mark an unexpected or as-needed dose', () async {
        await configure(since: after(const Duration(hours: -1)));
        await (f.db.update(
          f.db.medicationOccurrences,
        )..where((o) => o.id.equals(f.occurrence.id))).write(
          const MedicationOccurrencesCompanion(expected: Value(false)),
        );

        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');
      });

      test('does not mark a superseded dose', () async {
        await configure(since: after(const Duration(hours: -1)));
        await (f.db.update(f.db.medicationOccurrences)
              ..where((o) => o.id.equals(f.occurrence.id)))
            .write(MedicationOccurrencesCompanion(supersededAt: Value(clock)));

        expect((await sweeper().sweep()).recorded, 0);
      });

      test('skips a dose whose medication is gone and goes on', () async {
        await configure(since: after(const Duration(hours: -1)));
        final extra = (await addOccurrences(1)).single;
        // The first (oldest) dose points at a medication that no longer
        // exists; the second one must still be recorded.
        await f.db.customStatement('PRAGMA foreign_keys = OFF');
        await (f.db.update(
          f.db.medicationOccurrences,
        )..where((o) => o.id.equals(f.occurrence.id))).write(
          const MedicationOccurrencesCompanion(
            pillId: Value('20000000-0000-4000-8000-0000000000ff'),
          ),
        );

        final result = await sweeper().sweep();

        expect(result.aborted, isFalse);
        expect(result.recorded, 1);
        expect((await occurrence()).state, 'pending');
        expect((await occurrence(extra.id)).state, 'missed');
      });

      test('records at most 200 doses per run, oldest first', () async {
        await configure(since: after(const Duration(hours: -1)));
        final extra = await addOccurrences(204);
        clock = after(const Duration(hours: 6));

        final first = await sweeper().sweep();
        expect(first.recorded, autoMissBatchSize);
        final pending = await (f.db.select(
          f.db.medicationOccurrences,
        )..where((o) => o.state.equals('pending'))).get();
        expect(pending, hasLength(5));
        expect(
          pending.map((o) => o.id),
          containsAll([extra[199].id, extra.last.id]),
        );
        expect(
          pending.map((o) => o.id),
          isNot(contains(f.occurrence.id)),
          reason: 'the oldest dose goes first',
        );

        final second = await sweeper().sweep();
        expect(second.recorded, 5);
        expect(
          await (f.db.select(
            f.db.medicationOccurrences,
          )..where((o) => o.state.equals('pending'))).get(),
          isEmpty,
        );
      });

      test('two sweeps at once write one miss', () async {
        await configure(since: after(const Duration(hours: -1)));

        final results = await Future.wait([
          sweeper().sweep(),
          sweeper().sweep(),
        ]);

        // The second run meets the first one's receipt and writes nothing.
        expect(
          results.fold<int>(0, (sum, r) => sum + r.recorded),
          greaterThan(0),
        );
        expect(
          await f.db.medicationLedgerDao.getEventsForOccurrence(
            f.occurrence.id,
          ),
          hasLength(1),
        );
      });

      test('never asks the server about a local workspace', () async {
        await configure(since: after(const Duration(hours: -1)));
        supported = false;

        expect((await sweeper().sweep()).recorded, 1);
        expect(supportChecks, 0);
      });
    });

    group('periodic task', () {
      setUp(() async {
        f = await CareRecordingFixture.create();
        addTearDown(f.db.close);
        owner = f.workspace.context.ownerUserId;
      });

      test('records, then lets reminders and the widget follow', () async {
        await configure(since: after(const Duration(hours: -1)));
        var published = 0;

        final ok = await runProtectedAutoMiss(
          db: f.db,
          preferences: f.workspace.preferences,
          clock: () => clock,
          publish: (_, _) async => published++,
        );

        expect(ok, isTrue);
        expect(published, 1);
        expect((await occurrence()).state, 'missed');
      });

      test('stays quiet when there is nothing to record', () async {
        await configure(since: after(const Duration(hours: -1)));
        clock = after(const Duration(minutes: 5));
        var published = 0;

        final ok = await runProtectedAutoMiss(
          db: f.db,
          preferences: f.workspace.preferences,
          clock: () => clock,
          publish: (_, _) async => published++,
        );

        expect(ok, isTrue);
        expect(published, 0);
        expect((await occurrence()).state, 'pending');
      });

      test('does nothing at all while nobody uses the setting', () async {
        await configure(enabled: false);
        var published = 0;

        expect(
          await runProtectedAutoMiss(
            db: f.db,
            preferences: f.workspace.preferences,
            clock: () => clock,
            publish: (_, _) async => published++,
          ),
          isTrue,
        );
        expect(published, 0);
        expect((await occurrence()).state, 'pending');
      });

      test('a failing publication is not a failed task', () async {
        await configure(since: after(const Duration(hours: -1)));

        expect(
          await runProtectedAutoMiss(
            db: f.db,
            preferences: f.workspace.preferences,
            clock: () => clock,
            publish: (_, _) async => throw StateError('fictional'),
          ),
          isTrue,
        );
        expect((await occurrence()).state, 'missed');
      });
    });

    group('connected workspace', () {
      setUp(() async {
        f = await CareRecordingFixture.create(connected: true);
        addTearDown(f.db.close);
        owner = f.workspace.context.ownerUserId;
      });

      test('queues the miss as an ordinary command', () async {
        await configure(since: after(const Duration(hours: -1)));

        final result = await sweeper().sweep();

        expect(result.recorded, 1);
        final row = await occurrence();
        expect(row.state, 'missed');
        final ops = await medicationOps();
        expect(ops, hasLength(1));
        expect(ops.single.state, 'queued');
        expect(
          ops.single.mutationId,
          autoMissCommandId(
            ownerUserId: owner,
            occurrenceKey: f.occurrence.occurrenceKey,
          ),
        );
        expect(isAutoMissOperation(ops.single), isTrue);
        final payload = jsonDecode(ops.single.payloadJson) as Map;
        expect((payload['command'] as Map)['action'], 'miss');
        expect((payload['command'] as Map)['baseVersion'], '0');
        final details = await f.db.select(f.db.careEventDetails).get();
        expect(details.single.authorName, isNull);
      });

      test('two installs of one account derive the same command ID', () async {
        final other = await CareRecordingFixture.create(connected: true);
        addTearDown(other.db.close);
        expect(
          other.workspace.context.workspaceId,
          isNot(f.workspace.context.workspaceId),
          reason: 'workspace IDs are minted per install',
        );
        expect(other.workspace.context.ownerUserId, owner);

        await configure(since: after(const Duration(hours: -1)));
        await sweeper().sweep();
        await other.workspace.preferences.setBool(
          autoMissEnabledPreferenceKey(owner),
          true,
        );
        await other.workspace.preferences.setInt(
          autoMissSincePreferenceKey(owner),
          after(const Duration(hours: -1)).millisecondsSinceEpoch,
        );
        final otherResult = await AutoMissSweeper(
          db: other.db,
          access: other.workspace.access,
          preferences: other.workspace.preferences,
          clock: () => clock,
          serverRecordsMisses: () async => true,
        ).sweep();

        expect(otherResult.recorded, 1);
        final first = (await medicationOps()).single;
        final second = (await other.db.pendingOperationsDao.getForUser(
          owner,
        )).where((op) => op.component == 'medication').single;
        expect(second.mutationId, first.mutationId);
      });

      test('waits for a server that stores misses', () async {
        await configure(since: after(const Duration(hours: -1)));
        supported = false;

        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');
        expect(await medicationOps(), isEmpty);
        expect(
          f.workspace.preferences.getInt(autoMissSincePreferenceKey(owner)),
          clock.millisecondsSinceEpoch,
          reason: 'recording starts when the server can take it',
        );

        // The server now supports it: doses that went unrecorded while it did
        // not are not back-filled in a burst.
        supported = true;
        clock = after(const Duration(hours: 5));
        expect((await sweeper().sweep()).recorded, 0);
        expect((await occurrence()).state, 'pending');
      });

      test(
        'does not write the dose again after the server dropped it',
        () async {
          await configure(since: after(const Duration(hours: -1)));
          await sweeper().sweep();
          final op = (await medicationOps()).single;
          // The server answered "not applicable": the operation is discarded and
          // the occurrence goes back to pending.
          await f.db.pendingOperationsDao.transitionState(
            operationId: op.id,
            from: 'queued',
            to: 'sending',
          );
          expect(
            await discardAutoMissOperation(
              f.db,
              (await f.db.pendingOperationsDao.getById(op.id))!,
              from: 'sending',
              safeErrorCode: autoMissNotAppliedCode,
            ),
            isTrue,
          );
          expect((await occurrence()).state, 'pending');

          expect((await sweeper().sweep()).recorded, 0);
          expect((await occurrence()).state, 'pending');
          expect(await medicationOps(), hasLength(1));
        },
      );

      test('stops when access changes during the run', () async {
        await configure(since: after(const Duration(hours: -1)));

        final result = await sweeper(
          support: () async {
            await f.db.customStatement(
              'UPDATE workspace_grants SET epoch = epoch + 1',
            );
            return true;
          },
        ).sweep();

        expect(result.aborted, isTrue);
        expect(result.recorded, 0);
        expect((await occurrence()).state, 'pending');
        expect(await medicationOps(), isEmpty);
      });
    });
  });
}
