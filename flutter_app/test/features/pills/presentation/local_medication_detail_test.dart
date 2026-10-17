import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_detail_provider.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/pills/pill_repository.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/features/schedules/presentation/routine_detail_screen.dart';
import 'package:simpastil/features/pills/presentation/medication_detail_screen.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/features/pills/presentation/pills_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  testWidgets('saved local routine is not described as no active schedules', (
    tester,
  ) async {
    final fixture = await CareRecordingFixture.create();
    final container = await fixture.workspace.createContainer();
    addTearDown(() async {
      await fixture.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light(),
          home: const PillsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(fixture.pill.name), findsOneWidget);
    expect(find.text('No active schedules'), findsNothing);
    expect(find.textContaining('Every day'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'actual medication review and routine edit keep identity and old routine facts',
    (tester) async {
      _phone(tester);
      final f = await CareRecordingFixture.create();
      final container = await f.workspace.createContainer(
        extraOverrides: [
          pillRepositoryProvider.overrideWithValue(
            PillRepositoryImpl(
              db: f.db,
              dao: f.db.pillsDao,
              profilesDao: f.db.profilesDao,
              schedulesDao: f.db.schedulesDao,
              pendingOperations: PendingOperationRepository(
                f.db,
                access: f.workspace.access,
                context: f.workspace.context,
              ),
              reconcileProjections: () async {},
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
      final router = container.read(routerProvider)..go('/pills');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(alwaysUse24HourFormat: true),
              child: child!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(ValueKey('medication-${f.pill.id}')));
      expect(find.byType(MedicationDetailScreen), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('edit-medication-details')));
      await tester.enterText(
        find.byKey(const ValueKey('edit-medication-name')),
        'Fictional revised medication',
      );
      await _tap(tester, find.byType(SwitchListTile));
      await tester.enterText(
        find.byKey(const ValueKey('edit-medication-quantity')),
        '1/2',
      );
      await tester.enterText(
        find.byKey(const ValueKey('edit-medication-unit')),
        'tablet',
      );
      // The grouped form is taller than the test surface: put the keyboard
      // away first, as a person would, so the focused field does not pull
      // the sheet back to itself while Save is revealed.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('save-medication-review')));
      // The page kept its scroll position at the Edit button; the new name
      // is in the plate at the top.
      await tester.dragUntilVisible(
        find.text('Fictional revised medication'),
        find.byType(ListView).first,
        const Offset(0, 300),
      );
      expect(find.text('Fictional revised medication'), findsOneWidget);
      expect(find.text('1/2 tablet'), findsOneWidget);
      final detail = await _read(
        tester,
        container.read(medicationDetailProvider(f.pill.id).future),
      );
      expect(detail.pill.id, f.pill.id);
      expect(detail.review.amount.quantityText, '1/2');
      final original = detail.routineVersions.single;
      await _tap(tester, find.byKey(const ValueKey('open-routine-details')));
      await _tap(tester, find.byKey(const ValueKey('edit-routine')));
      // Saved zone remains fixed; changing it requires this explicit detail action.
      expect(find.text('Coordinated Universal Time'), findsOneWidget);
      await _tap(tester, find.text('Change time zone'));
      await tester.enterText(find.byType(TextField), 'Bucharest');
      await tester.pumpAndSettle();
      await _tap(tester, find.widgetWithText(ListTile, 'Bucharest, Romania'));
      await _tap(tester, find.text('Add another time'));
      final timeContext = tester.element(find.byType(TimePickerDialog));
      final material = MaterialLocalizations.of(timeContext);
      await tester.tap(find.byTooltip(material.inputTimeModeButtonLabel));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '19');
      await tester.enterText(fields.at(1), '30');
      await tester.tap(find.text(material.okButtonLabel));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('routine-time-1')), findsOneWidget);
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await _tap(tester, find.byKey(const ValueKey('routine-optional-dates')));
      await _date(tester, 'routine-start', tomorrow);
      await _date(tester, 'routine-end', tomorrow.add(const Duration(days: 4)));
      await _tap(tester, find.byKey(const ValueKey('review-routine')));
      expect(find.text('Current routine'), findsOneWidget);
      expect(find.text('Reviewed routine'), findsOneWidget);
      expect(find.textContaining('19:30'), findsWidgets);
      expect(find.text('Bucharest, Romania'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('save-routine')));
      final saved = await _read(
        tester,
        container.read(medicationDetailProvider(f.pill.id).future),
      );
      expect(saved.routineVersions, hasLength(2));
      expect(
        saved.routineVersions.first.definitionJson,
        original.definitionJson,
      );
      final changed = RoutineDefinition.fromJson(
        jsonDecode(saved.routineVersions.last.definitionJson)
            as Map<String, dynamic>,
      );
      expect(saved.routineVersions.last.routineId, original.routineId);
      expect(changed.timeZone, 'Europe/Bucharest');
      expect(changed.times.map((t) => t.slotId), contains('morning'));
      expect(
        changed.times.map((t) => '${t.hour}:${t.minute}'),
        contains('19:30'),
      );
      expect(changed.startDate, routineDateKey(tomorrow));
      expect(
        changed.endDate,
        routineDateKey(tomorrow.add(const Duration(days: 4))),
      );
      expect(
        changed.amount.isUnknown,
        isTrue,
        reason:
            'Medication default editing does not rewrite reviewed routine amounts',
      );
      expect(
        await _read(tester, f.db.select(f.db.pendingOperations).get()),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'future zone-only routine change retains both readable saved places',
    (tester) async {
      final f = await CareRecordingFixture.create();
      final now = DateTime.now().toUtc();
      final boundary = now.add(const Duration(days: 2));
      final repository = RoutineRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => now,
      );
      final original = (await repository.loadForPill(f.pill.id)).single;
      final definition = RoutineDefinition.fromJson(
        jsonDecode(original.definitionJson) as Map<String, dynamic>,
      );
      final review = await repository.preview(
        pillId: f.pill.id,
        routineId: original.routineId,
        expectedRevision: original.revision,
        definition: RoutineDefinition.fromJson({
          ...definition.toJson(),
          'timeZone': 'Europe/Paris',
        }),
        effectiveFrom: boundary,
        fromLocalDate: routineDateKey(boundary),
        throughLocalDate: routineDateKey(boundary.add(const Duration(days: 3))),
      );
      await repository.saveReviewed(review);
      final container = await f.workspace.createContainer();
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
            home: RoutineDetailScreen(pillId: f.pill.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Coordinated Universal Time'), findsOneWidget);
      expect(find.text('Paris · Europe'), findsOneWidget);
      expect(find.text('Changes from'), findsOneWidget);
      final versions = await _read(tester, repository.loadForPill(f.pill.id));
      expect(versions.first.definitionJson, original.definitionJson);
      expect(versions.last.effectiveFrom, review.effectiveFrom);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('open medication review conceals retained care after sign-out', (
    tester,
  ) async {
    final f = await CareRecordingFixture.create(connected: true);
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    final router = container.read(routerProvider)..go('/pills/${f.pill.id}');
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
    await _tap(tester, find.byKey(const ValueKey('edit-medication-details')));
    expect(find.byKey(const ValueKey('edit-medication-name')), findsOneWidget);
    await _read(tester, f.workspace.access.revokeNetwork());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-medication-name')), findsNothing);
    expect(find.text(f.pill.name), findsNothing);
    expect(find.byKey(const ValueKey('save-medication-review')), findsNothing);
    expect(
      (await _read(tester, f.db.pillsDao.getById(f.pill.id)))!.isDeleted,
      isFalse,
    );
  });

  for (final check in [0, 1, 2, 3]) {
    final checkStock = check == 0;
    final failSecond = check == 2;
    final checkSearch = check == 3;
    testWidgets(
      checkSearch
          ? 'search filters the visible list without changing exact bulk targets'
          : checkStock
          ? 'list preserves known negative stock warning'
          : failSecond
          ? 'partial bulk deletion keeps unsuccessful target and reports failure'
          : 'long press selects exact medications for confirmed bulk deletion',
      (tester) async {
        _phone(tester);
        final f = await CareRecordingFixture.create(legacyStock: -2);
        final setup = SetupRepository(
          database: f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        );
        var draft = await setup.resumeOrCreateDraft(
          purpose: SetupPurpose.medication,
          fixedPersonId: f.person.id,
        );
        draft = (await setup.saveMedication(
          draft.id,
          draft.revision,
          const MedicationReview(name: 'Fictional second medication'),
        )).draft;
        if (failSecond) {
          await f.db.customStatement(
            "CREATE TRIGGER fictional_delete_failure BEFORE UPDATE ON pills WHEN NEW.id = '${draft.medicationId}' AND NEW.is_deleted = 1 BEGIN SELECT RAISE(ABORT, 'fictional deletion failure'); END",
          );
        }
        final container = await f.workspace.createContainer(
          extraOverrides: [
            pillRepositoryProvider.overrideWithValue(
              PillRepositoryImpl(
                db: f.db,
                dao: f.db.pillsDao,
                profilesDao: f.db.profilesDao,
                schedulesDao: f.db.schedulesDao,
                pendingOperations: PendingOperationRepository(
                  f.db,
                  access: f.workspace.access,
                  context: f.workspace.context,
                ),
                reconcileProjections: () async {},
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
              home: const PillsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (checkStock) {
          expect(find.text('-2 left'), findsOneWidget);
          expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
          return;
        }
        if (checkSearch) {
          final search = find.byKey(const ValueKey('medication-search'));
          await tester.enterText(search, 'SECOND');
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('medication-${f.pill.id}')), findsNothing);
          final second = find.byKey(
            ValueKey('medication-${draft.medicationId}'),
          );
          expect(second, findsOneWidget);
          await tester.longPress(second);
          await tester.pumpAndSettle();
          await tester.enterText(search, 'No matching fictional medicine');
          await tester.pumpAndSettle();
          expect(find.text('No matching medications'), findsOneWidget);
          expect(find.text('1 selected'), findsOneWidget);
          await tester.enterText(search, '');
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<Checkbox>(
                  find.byKey(ValueKey('select-medication-${f.pill.id}')),
                )
                .value,
            isFalse,
          );
          expect(
            tester
                .widget<Checkbox>(
                  find.byKey(
                    ValueKey('select-medication-${draft.medicationId}'),
                  ),
                )
                .value,
            isTrue,
          );
          await _tap(tester, find.byTooltip('Delete selected pills'));
          expect(find.text('Delete 1 pill?'), findsOneWidget);
          await tester.tap(find.text('Delete'));
          await tester.pumpAndSettle();
          expect(
            (await _read(tester, f.db.pillsDao.getById(f.pill.id)))!.isDeleted,
            isFalse,
          );
          expect(
            (await _read(
              tester,
              f.db.pillsDao.getById(draft.medicationId!),
            ))!.isDeleted,
            isTrue,
          );
          return;
        }
        await tester.longPress(find.byKey(ValueKey('medication-${f.pill.id}')));
        await tester.pumpAndSettle();
        expect(find.byType(Checkbox), findsNWidgets(2));
        await _tap(
          tester,
          find.byKey(ValueKey('select-medication-${draft.medicationId}')),
        );
        await _tap(tester, find.byTooltip('Delete selected pills'));
        expect(find.text('Delete 2 pills?'), findsOneWidget);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        for (final id in [f.pill.id, draft.medicationId!]) {
          expect(
            (await _read(tester, f.db.pillsDao.getById(id)))!.isDeleted,
            !(failSecond && id == draft.medicationId),
          );
        }
        if (failSecond) {
          expect(
            tester
                .widget<Checkbox>(
                  find.byKey(
                    ValueKey('select-medication-${draft.medicationId}'),
                  ),
                )
                .value,
            isTrue,
          );
          expect(find.textContaining('1 pill deleted'), findsOneWidget);
          expect(find.textContaining("Could not delete"), findsOneWidget);
        } else {
          expect(find.text('2 pills deleted'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

/// A phone-sized window: these tests are about the phone's card list and page.
void _phone(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(412, 915)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _date(WidgetTester tester, String key, DateTime day) async {
  await _tap(tester, find.byKey(ValueKey(key)));
  final material = MaterialLocalizations.of(
    tester.element(find.byType(DatePickerDialog)),
  );
  await tester.tap(find.byTooltip(material.inputDateModeButtonLabel));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.byType(TextField),
    ),
    material.formatCompactDate(day),
  );
  await tester.tap(find.text(material.okButtonLabel));
  await tester.pumpAndSettle();
}

Future<T> _read<T>(WidgetTester tester, Future<T> operation) async {
  var done = false;
  T? value;
  Object? error;
  operation.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!done) throw StateError('Protected query did not settle');
  if (error != null) throw error!;
  return value as T;
}
