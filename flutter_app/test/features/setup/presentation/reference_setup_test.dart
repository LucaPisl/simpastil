import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../../helpers/protected_workspace_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final locale in ['en', 'ro']) {
    testWidgets(
      'reference form retains optional form through immediate Back and durable save $locale',
      (tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = await ProtectedWorkspaceFixture.create();
        final repository = SetupRepository(
          database: fixture.db,
          access: fixture.access,
          context: fixture.context,
        );
        var draft = await repository.resumeOrCreateDraft();
        draft = (await repository.savePerson(
          draft.id,
          draft.revision,
          name: 'Alex',
          avatar: 'A',
        )).draft;
        final container = await fixture.createContainer();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.db.close();
          container.dispose();
          await tester.pumpAndSettle();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: container.read(routerProvider),
              theme: AppTheme.light(),
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(locale == 'ro' ? 2 : 1),
                ),
                child: child!,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final form = find.byKey(const ValueKey('medication-form'));
        expect(form, findsOneWidget);
        if (locale == 'en') {
          expect(
            tester.getTopLeft(form).dy,
            tester
                .getTopLeft(find.byKey(const ValueKey('medication-strength')))
                .dy,
          );
          expect(
            find.byKey(const ValueKey('save-medication')).hitTestable(),
            findsOneWidget,
          );
        }
        await tester.enterText(
          find.byKey(const ValueKey('medication-name')),
          'Example tablet',
        );
        await tester.ensureVisible(form);
        await tester.pumpAndSettle();
        await tester.enterText(form, 'tablet');
        // The actual system Back must persist this field without a debounce wait.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('person-name')), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('save-person')));
        expect(tester.widget<TextFormField>(form).controller!.text, 'tablet');
        await _tap(tester, find.byKey(const ValueKey('save-medication')));
        final metadata = await _read(
          tester,
          fixture.db.select(fixture.db.medicationDetails).get(),
        );
        expect(metadata.single.form, 'tablet');
        expect(
          await _read(tester, fixture.db.select(fixture.db.pills).get()),
          hasLength(1),
        );
        expect(
          await _read(tester, fixture.db.select(fixture.db.schedules).get()),
          isEmpty,
        );
        expect(
          await _read(
            tester,
            fixture.db.select(fixture.db.pendingOperations).get(),
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
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
    (result) {
      value = result;
      done = true;
    },
    onError: (Object failure) {
      error = failure;
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
