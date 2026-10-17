import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(tzdata.initializeTimeZones);

  test(
    'foreground reads catch up with background Taken and Undo commits',
    () async {
      final fixture = await CareRecordingFixture.create(
        routineTimeZone: 'Europe/Bucharest',
        routineHour: 12,
      );
      final directory = await Directory.systemTemp.createTemp(
        'fictional-care-refresh-',
      );
      final file = File('${directory.path}/care.sqlite');
      await fixture.db.customStatement('VACUUM INTO ?', [file.path]);
      await fixture.db.close();
      final foreground = AppDatabase(NativeDatabase(file));
      final background = AppDatabase(NativeDatabase(file));
      final states = <String>[];
      final initial = Completer<void>();
      final takenObserved = Completer<void>();
      final undoObserved = Completer<void>();
      final subscription =
          (foreground.select(foreground.medicationOccurrences)
                ..where((row) => row.id.equals(fixture.occurrence.id)))
              .watchSingle()
              .listen((row) {
                states.add(row.state);
                if (!initial.isCompleted) initial.complete();
                if (row.state == 'taken' && !takenObserved.isCompleted) {
                  takenObserved.complete();
                }
                if (row.state == 'pending' &&
                    takenObserved.isCompleted &&
                    !undoObserved.isCompleted) {
                  undoObserved.complete();
                }
              });
      addTearDown(() async {
        await subscription.cancel();
        await background.close();
        await foreground.close();
        await directory.delete(recursive: true);
      });
      await initial.future;
      expect(states.last, 'pending');
      final access = WorkspaceAccessRepository(background);
      final context = await access.currentContext();
      final repository = MedicationRepository(
        background,
        access: access,
        context: context,
      );
      await repository.apply(
        userId: context.ownerUserId,
        occurrenceId: fixture.occurrence.id,
        action: MedicationAction.take,
        actualTimeKnown: true,
        actualAt: DateTime.utc(2026, 9, 30, 9, 15),
        commandIdOverride: '20000000-0000-4000-8000-000000000001',
      );
      expect(
        (await foreground.medicationLedgerDao.getOccurrenceById(
          fixture.occurrence.id,
        ))!.state,
        'taken',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        states.last,
        'pending',
        reason: 'Independent connections do not broadcast Drift updates.',
      );

      foreground.refreshExternalChanges();
      await takenObserved.future.timeout(const Duration(seconds: 2));
      expect(states.last, 'taken');
      final taken =
          (await background.medicationLedgerDao.getEventsForOccurrence(
            fixture.occurrence.id,
          )).single;
      await repository.apply(
        userId: context.ownerUserId,
        occurrenceId: fixture.occurrence.id,
        action: MedicationAction.undo,
        intendedState: MedicationState.pending,
        reversesEventId: taken.id,
        actualTimeKnown: false,
        commandIdOverride: '20000000-0000-4000-8000-000000000002',
      );
      foreground.refreshExternalChanges();
      await undoObserved.future.timeout(const Duration(seconds: 2));
      expect(states.last, 'pending');
      expect(
        await foreground.medicationLedgerDao.getEventsForOccurrence(
          fixture.occurrence.id,
        ),
        hasLength(2),
      );
      expect(
        await foreground.select(foreground.pendingOperations).get(),
        isEmpty,
      );
    },
  );
}
