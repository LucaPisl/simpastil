import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/setup/presentation/setup_organiser.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../../helpers/protected_workspace_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testWidgets(
    'finish later leaves setup and resumes the same unsaved medication',
    (tester) async {
      final f = await ProtectedWorkspaceFixture.create();
      final repo = SetupRepository(
        database: f.db,
        access: f.access,
        context: f.context,
      );
      var draft = await repo.resumeOrCreateDraft();
      draft = (await repo.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Mara',
        avatar: 'M',
      )).draft;
      final container = await f.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      final router = container.read(routerProvider);
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
      await tester.enterText(
        find.byKey(const ValueKey('medication-name')),
        'Fictional unfinished medication',
      );
      final later = find.text('Save and finish later');
      await tester.ensureVisible(later);
      await tester.pumpAndSettle();
      await tester.tap(later);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/pills');
      router.go('/home');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('medication-name')),
            )
            .controller!
            .text,
        'Fictional unfinished medication',
      );
      expect(find.text('For Fictional Mara'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Back immediately after typing retains unfinished medication and optional exits keep saved care',
    (tester) async {
      final f = await ProtectedWorkspaceFixture.create();
      final repo = SetupRepository(
        database: f.db,
        access: f.access,
        context: f.context,
      );
      var draft = await repo.resumeOrCreateDraft();
      draft = (await repo.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Mara',
        avatar: 'M',
      )).draft;
      final container = await f.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      final router = container.read(routerProvider);
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
      await tester.enterText(
        find.byKey(const ValueKey('medication-name')),
        'Fictional no routine',
      );
      // Deliberately no debounce wait before pressing Back.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('person-name')), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('save-person')));
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('medication-name')),
            )
            .controller!
            .text,
        'Fictional no routine',
      );
      await tester.enterText(
        find.byKey(const ValueKey('medication-name')),
        'Fictional no routine after system Back',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('person-name')), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('save-person')));
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('medication-name')),
            )
            .controller!
            .text,
        'Fictional no routine after system Back',
      );
      await _tap(tester, find.byKey(const ValueKey('save-medication')));
      await _tap(tester, find.text('Not now'));
      await _tap(tester, find.byKey(const ValueKey('reminders-continue')));
      await _tap(tester, find.byKey(const ValueKey('project-note-continue')));
      expect(
        find.text('Fictional no routine after system Back'),
        findsOneWidget,
      );
      // The organiser lies flat on the setup page before Today replaces it.
      final openToday = find.byKey(const ValueKey('open-today'));
      await tester.ensureVisible(openToday);
      await tester.pumpAndSettle();
      await tester.tap(openToday);
      await tester.pump();
      await tester.pump(SetupOrganiser.finishing ~/ 2);
      final organiser =
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byType(SetupOrganiser),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as OrganiserPainter;
      expect(organiser.finish.value, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(find.byType(SetupOrganiser), findsNothing);
      expect(find.byKey(const ValueKey('medication-name')), findsNothing);
      final pills = await _read(tester, f.db.select(f.db.pills).get());
      expect(pills.single.name, 'Fictional no routine after system Back');
      expect(
        await _read(tester, f.db.select(f.db.localRoutines).get()),
        isEmpty,
      );
      expect(await _read(tester, repo.findUnfinishedDraft()), isNull);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
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
