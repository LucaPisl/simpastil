import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../../helpers/protected_workspace_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('empty medication action carries the exact displayed person', (
    tester,
  ) async {
    final f = await ProtectedWorkspaceFixture.create();
    final setup = SetupRepository(
      database: f.db,
      access: f.access,
      context: f.context,
    );
    final jamie = await _person(setup, 'Jamie');
    final sam = await _person(setup, 'Sam');
    final container = await f.createContainer();
    await container.read(selectedProfileIdProvider.notifier).select(jamie);
    Uri? entry;
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const FocusTodayScreen()),
        GoRoute(
          path: '/setup',
          builder: (_, state) {
            entry = state.uri;
            return const Scaffold(body: Text('Captured setup entry'));
          },
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No medications yet'), findsOneWidget);
    expect(
      find.text('Add a medication for Jamie when you’re ready.'),
      findsOneWidget,
    );
    final action = find.widgetWithText(FilledButton, 'Add medication');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(entry?.queryParameters['purpose'], 'medication');
    expect(entry?.queryParameters['person'], jamie);
    await _read(
      tester,
      container.read(selectedProfileIdProvider.notifier).select(sam),
    );
    await tester.pumpAndSettle();
    expect(entry?.queryParameters['person'], jamie);
    expect(await _read(tester, f.db.select(f.db.pills).get()), isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final large in [false, true]) {
    testWidgets(
      'day off keeps the dated next dose and actual PRN, large=$large',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = await ProtectedWorkspaceFixture.create();
        final setup = SetupRepository(
          database: f.db,
          access: f.access,
          context: f.context,
        );
        final personName = large
            ? 'FictionalJamieWithAnUnbrokenLongName'
            : 'Jamie';
        final personId = await _person(setup, personName);
        final medicationName = large
            ? 'ExampleWeekendMedicationWithALongName'
            : 'Example weekend';
        final routines = RoutineRepository(
          database: f.db,
          access: f.access,
          context: f.context,
          clock: () => DateTime.utc(2026, 9, 30, 7),
        );
        String? scheduledPill;
        for (final prn in [false, true]) {
          var draft = await setup.resumeOrCreateDraft(
            purpose: SetupPurpose.medication,
            fixedPersonId: personId,
          );
          draft = (await setup.saveMedication(
            draft.id,
            draft.revision,
            MedicationReview(name: prn ? 'Example as needed' : medicationName),
          )).draft;
          if (!prn) scheduledPill = draft.medicationId;
          await routines.saveReviewed(
            await routines.preview(
              pillId: draft.medicationId!,
              expectedRevision: 0,
              definition: RoutineDefinition(
                kind: prn ? RoutineKind.prn : RoutineKind.weekdays,
                timeZone: 'Europe/Bucharest',
                weekdays: prn ? const [] : const [DateTime.saturday],
                times: prn
                    ? const []
                    : const [
                        RoutineTime(slotId: 'morning', hour: 8, minute: 0),
                      ],
              ),
              effectiveFrom: DateTime.utc(2026, 9, 30, 7),
              fromLocalDate: '2026-09-30',
              throughLocalDate: '2026-09-30',
            ),
          );
          draft = await setup.advanceOrSkip(
            draft.id,
            draft.revision,
            SetupStep.ready,
          );
          await setup.advanceOrSkip(
            draft.id,
            draft.revision,
            SetupStep.complete,
          );
        }
        final container = await f.createContainer(
          extraOverrides: [
            deviceTimeZoneProvider.overrideWith(
              (ref) async => 'Europe/Bucharest',
            ),
          ],
        );
        await container
            .read(selectedProfileIdProvider.notifier)
            .select(personId);
        container
            .read(selectedDateProvider.notifier)
            .select(DateTime(2026, 9, 30));
        String? routedPill;
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const FocusTodayScreen()),
            GoRoute(
              path: '/pills/:pillId/routine',
              builder: (_, state) {
                routedPill = state.pathParameters['pillId'];
                return const Scaffold(body: Text('Exact routine'));
              },
            ),
          ],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
          await f.db.close();
          container.dispose();
          await tester.pumpAndSettle();
        });
        final locale = large ? 'ro' : 'en';
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: large ? AppTheme.dark() : AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(large ? 2 : 1)),
                child: child!,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scrollable = find.byType(Scrollable).first;
        final heading = find.text(
          large
              ? 'Nimic programat în această zi'
              : 'Nothing scheduled for this day',
        );
        await tester.scrollUntilVisible(heading, 180, scrollable: scrollable);
        expect(
          find.text(
            large
                ? 'Nimic programat în această zi'
                : 'Nothing scheduled for this day',
          ),
          findsOneWidget,
        );
        final date = DateFormat.yMMMEd(locale).format(DateTime(2026, 10, 3));
        final dateLabel = '${large ? 'Urmează' : 'Next'} · $date';
        await tester.scrollUntilVisible(
          find.text(dateLabel),
          180,
          scrollable: scrollable,
        );
        expect(find.text(dateLabel), findsOneWidget);
        expect(find.text(large ? '08:00' : '8:00 AM'), findsOneWidget);
        expect(find.text(medicationName), findsOneWidget);
        expect(find.textContaining('Tomorrow'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('Example as needed'),
          180,
          scrollable: scrollable,
        );
        expect(find.text('Example as needed'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final action = find.widgetWithText(
          OutlinedButton,
          large ? 'Vezi rutina' : 'View routine',
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        expect(action.hitTestable(), findsOneWidget);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(routedPill, scheduledPill);
        expect(
          await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<String> _person(SetupRepository setup, String name) async {
  final draft = await setup.resumeOrCreateDraft(purpose: SetupPurpose.person);
  final saved = await setup.savePerson(
    draft.id,
    draft.revision,
    name: name,
    avatar: name.substring(0, 1),
  );
  await setup.advanceOrSkip(draft.id, saved.draft.revision, SetupStep.complete);
  return saved.savedId;
}

Future<T> _read<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  T? value;
  Object? error;
  future.then(
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
  if (!done) throw StateError('Query did not settle');
  if (error != null) throw error!;
  return value as T;
}
