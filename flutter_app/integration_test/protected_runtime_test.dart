import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:home_widget/home_widget.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:workmanager/workmanager.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/widget/protected_widget_publisher.dart';
import 'package:simpastil/core/widget/widget_snapshot.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/main.dart' as production;

Future<String> _retainedWork(AppDatabase db) async => jsonEncode({
  'pending':
      (await db.select(db.pendingOperations).get())
          .map((row) => row.toJson())
          .toList()
        ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String)),
  'effects':
      (await db.select(db.pendingOperationEffects).get())
          .map((row) => row.toJson())
          .toList()
        ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String)),
  'staging': (await db.select(db.syncStagingItems).get())
      .map((row) => row.toJson())
      .toList(),
});

/// Run after the storage migration/restart probes on the explicitly owned AVD.
/// This backend fixture mounts no SimpastilRuntime/foreground reconciler.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'production native local care and headless retirement',
    (tester) async {
      expect(
        const bool.fromEnvironment('SIMPASTIL_DISPOSABLE_TEST') &&
            Platform.isAndroid,
        isTrue,
      );
      final db = AppDatabase();
      try {
        // Refuse to overwrite an unrecognized or previously populated fixture.
        expect((await db.usersDao.getAll()).map((row) => row.id), ['user-1']);
        expect(
          (await db.profilesDao.getByUserId('user-1')).map((row) => row.id),
          ['profile-1'],
        );
        expect(await db.select(db.pendingOperations).get(), hasLength(3));
        expect(
          (await db.select(db.pendingOperationEffects).get()).every(
            (row) => row.state == 'uncertain',
          ),
          isTrue,
        );
        final retained = await _retainedWork(db);
        final legacy = (await db.select(db.careWorkspaces).get()).single;
        expect(legacy.bindingState, 'unresolved');
        expect(legacy.currentAuthorId, isNull);
        final access = WorkspaceAccessRepository(
          db,
          effectsGate: privateProjectionEffectsGate,
        );
        final context = await access.currentContext();
        expect(context.isLocal, isTrue);
        expect(await access.currentNetworkCapability(), isNull);
        final repository = ProfileRepositoryImpl(
          dao: db.profilesDao,
          pendingOperations: PendingOperationRepository(
            db,
            access: access,
            context: context,
          ),
          userId: context.ownerUserId,
          access: access,
          context: context,
          reconcileProjections: () async {},
        );
        final first = await repository.create('Fictional Alex', 'A');
        final second = await repository.create('Fictional Robin', 'R');
        expect(first, isA<Ok<Profile>>());
        expect(second, isA<Ok<Profile>>());
        final person = (first as Ok<Profile>).value;
        final other = (second as Ok<Profile>).value;
        expect(await repository.toggleActive(person.id, true), isA<Ok<void>>());
        await access.viewPerson(context, other.id);
        expect((await access.currentContext()).authorId, context.authorId);
        expect(
          (await access.workspaces.reminderPeople(
            context.ownerUserId,
          )).map((row) => row.id),
          [person.id],
        );
        expect(
          await db.pendingOperationsDao.getForUser(context.ownerUserId),
          isEmpty,
        );

        // A concrete versioned display row; this does not claim local recording.
        final now = DateTime.now().toUtc();
        final day =
            '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final time =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:00';
        final pillId = const Uuid().v4();
        final scheduleId = const Uuid().v4();
        final occurrenceId = const Uuid().v4();
        await access.withGrant(context, () async {
          await db.pillsDao.upsert(
            PillsCompanion.insert(
              id: pillId,
              profileId: person.id,
              name: 'Fictional displayed medication',
              syncStatus: const Value('local'),
              createdAt: now,
              updatedAt: now,
            ),
          );
          await db.schedulesDao.upsert(
            SchedulesCompanion.insert(
              id: scheduleId,
              pillId: pillId,
              hour: now.hour,
              minute: now.minute,
              frequency: 'daily',
              syncStatus: const Value('local'),
              createdAt: now,
              updatedAt: now,
            ),
          );
          await db.medicationLedgerDao.upsertOccurrence(
            MedicationOccurrencesCompanion.insert(
              id: occurrenceId,
              userId: context.ownerUserId,
              pillId: Value(pillId),
              scheduleId: Value(scheduleId),
              occurrenceKey: 'fictional-native:$scheduleId:$day',
              source: 'scheduled',
              plannedLocalDate: day,
              plannedLocalTime: Value(time),
              timeZone: 'UTC',
              plannedAt: Value(
                DateTime.utc(
                  now.year,
                  now.month,
                  now.day,
                  now.hour,
                  now.minute,
                ),
              ),
              expected: const Value(true),
              provenance: 'exact',
              scheduleRevision: const Value(1),
              scheduleSnapshotJson: jsonEncode(
                ScheduleSnapshotV1(
                  pillName: 'Fictional displayed medication',
                  dosage: null,
                  frequency: 'daily',
                  frequencyDays: null,
                  hour: now.hour,
                  minute: now.minute,
                  timeZone: 'UTC',
                  profileId: person.id,
                  profileName: person.name,
                ).toJson(),
              ),
              createdAt: now,
              updatedAt: now,
            ),
          );
        });
        final localIdentity = ProjectionIdentity.fromContext(context);
        await publishWidgetSnapshot(
          db: db,
          access: access,
          projectionIdentity: localIdentity,
        );
        final activeMarker = await HomeWidget.getWidgetData<String>(
          widgetProjectionIdentityKey,
        );
        final activeBody = await HomeWidget.getWidgetData<String>(
          kTodayDosesKey,
        );
        expect(localIdentity.owns(jsonDecode(activeMarker!)), isTrue);
        final body = jsonDecode(activeBody!) as Map;
        expect(body['authenticated'], isTrue);
        expect((body['doses'] as List).single['stateVersion'], 0);
        expect((body['doses'] as List).single['occurrenceId'], occurrenceId);

        final retired = ProjectionIdentity(
          workspaceId: legacy.id,
          ownerId: 'user-1',
          grantEpoch: 1,
        );
        expect(await retired.retirementRequired(access), isTrue);
        final platform = NativeWidgetProjectionPlatform();
        final intent = jsonEncode(retired.toJson());
        await platform.save(widgetProjectionRetirementKey, intent);
        expect(await platform.read(widgetProjectionRetirementKey), intent);
        // Only the exact production WorkManager dispatcher may clear this key.
        // No foreground publisher/reconciler runs during the observation window.
        final unique = 'fictional-t03-headless-${const Uuid().v4()}';
        await Workmanager().initialize(production.callbackDispatcher);
        try {
          await Workmanager().registerOneOffTask(
            unique,
            'fictional-t03-headless-retirement',
            tag: unique,
            existingWorkPolicy: ExistingWorkPolicy.keep,
          );
          final waiting = Stopwatch()..start();
          while (await platform.read(widgetProjectionRetirementKey) != null &&
              waiting.elapsed < const Duration(seconds: 45)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          expect(
            await platform.read(widgetProjectionRetirementKey),
            isNull,
            reason:
                'Exact native background callback must consume the known retirement intent',
          );
          expect(
            await platform.read(widgetProjectionIdentityKey),
            activeMarker,
          );
          expect(await platform.read(kTodayDosesKey), activeBody);
          expect(await _retainedWork(db), retained);
          expect((await access.currentContext()).authorId, context.authorId);
          expect(
            (await db.profilesDao.getByUserId(
              context.ownerUserId,
            )).map((row) => row.id).toSet(),
            {person.id, other.id},
          );
          expect(
            (await access.workspaces.byId(
              context.workspaceId,
            ))!.selectedProfileId,
            other.id,
          );
          expect(
            (await access.workspaces.reminderPeople(
              context.ownerUserId,
            )).map((row) => row.id),
            [person.id],
          );
          // Fictional unique task only; no keys, care payloads or private paths.
          // ignore: avoid_print
          print(
            'PASS: native local author/people preserved; production headless retirement consumed; network sync skipped; task $unique',
          );
        } finally {
          await Workmanager().cancelByUniqueName(unique);
        }
      } finally {
        await db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
