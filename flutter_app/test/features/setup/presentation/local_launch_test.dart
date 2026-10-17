import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:simpastil/features/setup/presentation/setup_organiser.dart';
import 'package:simpastil/features/setup/presentation/setup_screen.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/shared/scene/horizon_scene.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../../helpers/protected_workspace_fixture.dart';

class _NoSession extends TokenService {
  @override
  Future<String?> getApiKey() async => null;
  @override
  Future<bool> hasSession() async => false;
}

class _NoServer extends ServerConfigNotifier {
  @override
  String? build() => null;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testWidgets(
    'fresh protected local care reaches fixed setup without a server',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await ProtectedWorkspaceFixture.create();
      final container = await fixture.createContainer(
        extraOverrides: [
          tokenServiceProvider.overrideWithValue(_NoSession()),
          serverConfigProvider.overrideWith(_NoServer.new),
          deviceTimeZoneProvider.overrideWith(
            (ref) async => 'Europe/Bucharest',
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.db.close();
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
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        isNot(AppPaths.login),
      );
      expect(find.byKey(const ValueKey('setup-start')), findsOneWidget);
      // The welcome shows the empty organiser; the sun is Today's alone.
      expect(
        tester.widget<SetupOrganiser>(find.byType(SetupOrganiser)).filled,
        0,
      );
      expect(find.byType(HorizonScene), findsNothing);
      final restore = find.ancestor(
        of: find.text('Restore a backup'),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(restore).onTap, isNotNull);
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(find.text('Create backup'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();

      expect(
        await _read(tester, fixture.db.select(fixture.db.setupDrafts).get()),
        isEmpty,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('setup-begin')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-begin')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('person-name')),
        'Fictional Mara',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-person')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-person')));
      await tester.pumpAndSettle();
      // Back revisits saved data; Continue must not create a second person.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('save-person')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-person')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('medication-name')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('medication-name')),
        'Fictional manual medication',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-medication')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-medication')));
      await tester.pumpAndSettle();
      expect(find.text('Medication saved'), findsOneWidget);
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
      await tester.ensureVisible(find.byKey(const ValueKey('add-routine')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-routine')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('routine-zone')), findsNothing);
      expect(find.text('Europe/Bucharest'), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('review-routine')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('review-routine')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('routine-preview')), findsOneWidget);
      expect(find.text('Europe/Bucharest'), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('save-routine')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-routine')));
      await tester.pumpAndSettle();
      expect(find.text('Routine saved'), findsOneWidget);
      expect(
        await _read(tester, fixture.db.select(fixture.db.localRoutines).get()),
        hasLength(1),
      );
      final savedRoutine = (await _read(
        tester,
        fixture.db.select(fixture.db.localRoutines).get(),
      )).single;
      expect(
        (jsonDecode(savedRoutine.definitionJson) as Map)['timeZone'],
        'Europe/Bucharest',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('routine-continue')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('routine-continue')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('reminders-continue')),
      );
      await tester.tap(find.byKey(const ValueKey('reminders-continue')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-today')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('setup-start')), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
        hasLength(3),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'unavailable phone time preserves medication and can be retried',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
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
      draft = await repository.advanceOrSkip(
        draft.id,
        draft.revision,
        SetupStep.person,
      );
      draft = (await repository.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Elena',
        avatar: '🙂',
      )).draft;
      await repository.saveMedication(
        draft.id,
        draft.revision,
        const MedicationReview(name: 'Fictional saved medication'),
      );
      var reads = 0;
      final container = await fixture.createContainer(
        extraOverrides: [
          deviceTimeZoneProvider.overrideWith((ref) async {
            if (++reads == 1) {
              throw StateError('Fictional unavailable device clock');
            }
            return 'Europe/Bucharest';
          }),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SetupScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-routine')));
      await tester.pumpAndSettle();
      final review = find.byKey(const ValueKey('review-routine'));
      expect(tester.widget<FilledButton>(review).onPressed, isNull);
      expect(find.byKey(const ValueKey('routine-zone')), findsNothing);
      expect(
        await _read(tester, fixture.db.select(fixture.db.pills).get()),
        hasLength(1),
      );
      expect(
        await _read(tester, fixture.db.select(fixture.db.localRoutines).get()),
        isEmpty,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('retry-device-time')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('retry-device-time')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(review).onPressed, isNotNull);
      await tester.ensureVisible(review);
      await tester.pumpAndSettle();
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(find.text('Next planned doses'), findsOneWidget);
      expect(find.text('Europe/Bucharest'), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('save-routine')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-routine')));
      await tester.pumpAndSettle();
      final saved = (await _read(
        tester,
        fixture.db.select(fixture.db.localRoutines).get(),
      )).single;
      expect(
        (jsonDecode(saved.definitionJson) as Map)['timeZone'],
        'Europe/Bucharest',
      );
      expect(reads, 2);
      expect(tester.takeException(), isNull);
    },
  );
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
    onError: (Object e, StackTrace s) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!done) {
    throw StateError('Live database query did not finish while pumping');
  }
  if (error != null) throw error!;
  return value as T;
}
