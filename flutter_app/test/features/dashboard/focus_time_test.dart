import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/protected_workspace_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final romanian in [false, true]) {
    testWidgets(
      'travel times keep both dates and fixed routine zone ${romanian ? 'RO' : 'EN'}',
      (tester) async {
        final f = await ProtectedWorkspaceFixture.create();
        final setup = SetupRepository(
          database: f.db,
          access: f.access,
          context: f.context,
        );
        var draft = await setup.resumeOrCreateDraft();
        draft = (await setup.savePerson(
          draft.id,
          draft.revision,
          name: 'Fictional Mara',
          avatar: 'M',
        )).draft;
        draft = (await setup.saveMedication(
          draft.id,
          draft.revision,
          const MedicationReview(name: 'Fictional midnight medication'),
        )).draft;
        final repository = RoutineRepository(
          database: f.db,
          access: f.access,
          context: f.context,
          clock: () => DateTime.utc(2026, 9, 29),
        );
        final saved = await repository.saveReviewed(
          await repository.preview(
            pillId: draft.medicationId!,
            expectedRevision: 0,
            definition: RoutineDefinition(
              kind: RoutineKind.daily,
              timeZone: 'Europe/Bucharest',
              times: [const RoutineTime(slotId: 'night', hour: 0, minute: 30)],
            ),
            effectiveFrom: DateTime.utc(2026, 9, 29),
            fromLocalDate: '2026-09-30',
            throughLocalDate: '2026-09-30',
          ),
        );
        final day = await CareDayRepository(
          database: f.db,
          access: f.access,
          context: f.context,
        ).load(localDate: '2026-09-30');
        var deviceZone = 'Europe/London';
        final container = await f.createContainer(
          extraOverrides: [
            deviceTimeZoneProvider.overrideWith((ref) async => deviceZone),
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
              locale: Locale(romanian ? 'ro' : 'en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: romanian ? AppTheme.dark() : AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(alwaysUse24HourFormat: true),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(child: FocusDeck(day: day)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Europe/Bucharest'), findsNothing);
        final label = tester
            .widget<Text>(find.byKey(const ValueKey('focus-travel-time')))
            .data!;
        expect(label, contains('00:30'));
        expect(label, contains('22:30'));
        expect(label, contains('30'));
        expect(label, contains('29'));
        expect(label, contains(romanian ? 'București' : 'Bucharest'));
        expect(label, contains(romanian ? 'aici' : 'here'));
        deviceZone = 'Europe/Bucharest';
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('focus-travel-time')), findsNothing);
        expect(find.text('Europe/Bucharest'), findsNothing);
        expect(
          (await _read(
            tester,
            repository.loadForPill(draft.medicationId!),
          )).single.definitionJson,
          saved.definitionJson,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
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
    onError: (Object failure, StackTrace _) {
      error = failure;
      done = true;
    },
  );
  for (var frame = 0; frame < 200 && !done; frame++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (error != null) throw error!;
  if (!done) throw StateError('Database read did not finish');
  return value as T;
}
