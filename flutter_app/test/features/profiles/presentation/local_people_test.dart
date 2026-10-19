import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/features/profiles/presentation/profiles_screen.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/storage/recorded_by_preference.dart';
import '../../../helpers/protected_workspace_fixture.dart';
import '../../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testWidgets(
    'local person reminders opt in and out without changing activity',
    (tester) async {
      final f = await CareRecordingFixture.create();
      await f.db.profilesDao.setActive(f.person.id, false);
      var reconciliations = 0;
      final container = await f.workspace.createContainer(
        extraOverrides: [
          profileRepositoryProvider.overrideWith(
            (ref) => ProfileRepositoryImpl(
              dao: f.db.profilesDao,
              pendingOperations: ref.read(pendingOperationRepositoryProvider),
              userId: f.workspace.context.ownerUserId,
              context: f.workspace.context,
              access: f.workspace.access,
              reconcileProjections: () async {
                reconciliations++;
              },
            ),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ProfilesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('person-actions-${f.person.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Reminders on this device'), findsOneWidget);
      await tester.tap(find.text('Reminders on this device'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('person-device-reminders'));
      // A person added on this device starts on.
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(
        (await f.db.select(f.db.devicePersonReminders).get()).single.enabled,
        isFalse,
      );
      expect((await f.db.profilesDao.getById(f.person.id))!.isActive, isFalse);
      expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(
        (await f.db.select(f.db.devicePersonReminders).get()).single.enabled,
        isTrue,
      );
      expect((await f.db.profilesDao.getById(f.person.id))!.isActive, isFalse);
      expect(reconciliations, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'compact People summary does not call an already recorded future dose Next',
    (tester) async {
      final f = await CareRecordingFixture.create(routineHour: 23);
      final c = f.workspace.context;
      final day = await CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: c,
      ).load(localDate: routineDateKey(DateTime.now()), personId: f.person.id);
      final entry = day.entries.single;
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: c,
      );
      await service.commit(
        await service.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: entry.occurrence.id,
          expectedStateVersion: entry.occurrence.stateVersion,
        ),
      );
      final setup = SetupRepository(
        database: f.db,
        access: f.workspace.access,
        context: c,
      );
      var draft = await setup.resumeOrCreateDraft(purpose: SetupPurpose.person);
      draft = (await setup.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional second person',
        avatar: 'S',
      )).draft;
      await setup.advanceOrSkip(draft.id, draft.revision, SetupStep.complete);
      final container = await f.workspace.createContainer();
      await container
          .read(selectedProfileIdProvider.notifier)
          .select(draft.personId);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ProfilesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final summary = find.byKey(ValueKey('person-summary-${f.person.id}'));
      await tester.scrollUntilVisible(
        summary,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: summary, matching: find.text('Taken')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: summary, matching: find.textContaining('Next ·')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('People shows current routine facts and follows Taken and Undo', (
    tester,
  ) async {
    final f = await CareRecordingFixture.create();
    // A custom source with no typed name leaves the author unnamed.
    SharedPreferences.setMockInitialValues({
      recordedByModePreferenceKey(f.workspace.context.ownerUserId): 'custom',
    });
    final context = f.workspace.context;
    final day = await CareDayRepository(
      database: f.db,
      access: f.workspace.access,
      context: context,
    ).load(localDate: routineDateKey(DateTime.now()), personId: f.person.id);
    final entry = day.entries.single;
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await f.db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ProfilesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fictional recorded medication'), findsOneWidget);
    expect(find.text('9:00 AM'), findsOneWidget);
    expect(find.text('Not recorded'), findsOneWidget);
    expect(find.text('View routine'), findsOneWidget);
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: context,
    );
    final receipt = await tester.runAsync(
      () async => service.commit(
        await service.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: entry.occurrence.id,
          expectedStateVersion: entry.occurrence.stateVersion,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Taken'), findsOneWidget);
    expect(find.textContaining('Author name not recorded'), findsOneWidget);
    await tester.runAsync(
      () async => service.commit(await service.prepareUndo(receipt!)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Not recorded'), findsOneWidget);
    expect(find.text('Taken'), findsNothing);
    expect(find.textContaining('Author name not recorded'), findsNothing);
    expect(tester.takeException(), isNull);
    // Undo removes the recorded-by stream listener. Let Drift's deferred
    // zero-delay stream-close callback run before widget-test timer checks.
    await tester.pump(const Duration(milliseconds: 1));
  });
  testWidgets('People shows a recorded miss as missed, then taken late', (
    tester,
  ) async {
    // A miss is refused until the planned instant has passed. Midnight in the
    // easternmost zone (UTC+14) has passed for today's date in every zone, so
    // the test does not depend on when or where it runs.
    final f = await CareRecordingFixture.create(
      routineTimeZone: 'Pacific/Kiritimati',
      routineHour: 0,
      routineEffectiveFrom: DateTime.utc(2026, 9, 29, 8),
    );
    final context = f.workspace.context;
    final days = CareDayRepository(
      database: f.db,
      access: f.workspace.access,
      context: context,
    );
    final today = routineDateKey(DateTime.now());
    final entry = (await days.load(
      localDate: today,
      personId: f.person.id,
    )).entries.single;
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await f.db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ProfilesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Not recorded'), findsOneWidget);

    await tester.runAsync(
      () => f.recordMiss(occurrenceId: entry.occurrence.id),
    );
    await tester.pumpAndSettle();
    expect(find.text('Missed'), findsOneWidget);
    expect(find.text('Not recorded'), findsNothing);
    // The app wrote the miss: no author and no actual time to show.
    expect(find.text('Marked missed automatically'), findsOneWidget);
    expect(find.textContaining('Author'), findsNothing);

    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: context,
    );
    final missed = await tester.runAsync(
      () async => (await days.load(
        localDate: today,
        personId: f.person.id,
      )).entries.single,
    );
    await tester.runAsync(
      () async => service.commit(
        await service.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: missed!.occurrence.id,
          expectedStateVersion: missed.occurrence.stateVersion,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Taken (late)'), findsOneWidget);
    expect(find.text('Missed'), findsNothing);
    expect(find.text('Marked missed automatically'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 1));
  });
  testWidgets(
    'mounted People count follows a saved medication without profile reload',
    (tester) async {
      final f = await ProtectedWorkspaceFixture.create();
      final repo = SetupRepository(
        database: f.db,
        access: f.access,
        context: f.context,
      );
      var personDraft = await repo.resumeOrCreateDraft(
        purpose: SetupPurpose.person,
      );
      personDraft = (await repo.savePerson(
        personDraft.id,
        personDraft.revision,
        name: 'Fictional reactive person',
        avatar: 'R',
      )).draft;
      await repo.advanceOrSkip(
        personDraft.id,
        personDraft.revision,
        SetupStep.complete,
      );
      final container = await f.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      final router = container.read(routerProvider)..go('/people/manage');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('0 medications'), findsOneWidget);
      await tester.runAsync(() async {
        var draft = await repo.resumeOrCreateDraft(
          purpose: SetupPurpose.medication,
          fixedPersonId: personDraft.personId,
        );
        draft = (await repo.saveMedication(
          draft.id,
          draft.revision,
          const MedicationReview(name: 'Fictional newly saved medicine'),
        )).draft;
      });
      await tester.pumpAndSettle();
      expect(find.text('1 medication'), findsOneWidget);
      expect(find.text('0 medications'), findsNothing);
    },
  );
  testWidgets(
    'second local person stays visible independent of legacy active flag',
    (tester) async {
      final f = await ProtectedWorkspaceFixture.create();
      final repo = SetupRepository(
        database: f.db,
        access: f.access,
        context: f.context,
      );
      var draft = await repo.resumeOrCreateDraft(purpose: SetupPurpose.person);
      draft = (await repo.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Mara',
        avatar: 'M',
      )).draft;
      await repo.advanceOrSkip(draft.id, draft.revision, SetupStep.complete);
      await (f.db.update(f.db.profiles)
            ..where((p) => p.id.equals(draft.personId!)))
          .write(const ProfilesCompanion(isActive: Value(false)));
      final container = await f.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      final router = container.read(routerProvider)..go('/people/manage');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fictional Mara'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('View care'), findsOneWidget);
      await tester.tap(find.byTooltip('Add profile'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('person-name')),
        'Fictional second person with a long name',
      );
      final save = find.byKey(const ValueKey('save-person'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/profiles');
      expect(find.text('Fictional Mara'), findsOneWidget);
      expect(
        find.text('Fictional second person with a long name'),
        findsNWidgets(2),
      );
      expect(find.text('View care'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('tapping another person row puts them in focus on Today', (
    tester,
  ) async {
    final f = await ProtectedWorkspaceFixture.create();
    final repo = SetupRepository(
      database: f.db,
      access: f.access,
      context: f.context,
    );
    final ids = <String>[];
    for (final (name, avatar) in [
      ('Fictional Mara', 'M'),
      ('Fictional Ilse', 'I'),
    ]) {
      var draft = await repo.resumeOrCreateDraft(purpose: SetupPurpose.person);
      draft = (await repo.savePerson(
        draft.id,
        draft.revision,
        name: name,
        avatar: avatar,
      )).draft;
      await repo.advanceOrSkip(draft.id, draft.revision, SetupStep.complete);
      ids.add(draft.personId!);
    }
    final container = await f.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await container.read(selectedProfileIdProvider.notifier).select(ids.first);
    final router = container.read(routerProvider)..go('/profiles');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('person-summary-${ids.last}'));
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(container.read(selectedProfileIdProvider).value, ids.last);
    expect(router.routeInformationProvider.value.uri.path, '/home');
    expect(tester.takeException(), isNull);
  });
}
