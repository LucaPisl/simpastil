import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/medication/routine_provider.dart';
import 'package:simpastil/features/schedules/presentation/routine_editor.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../../../helpers/care_recording_fixture.dart';
import '../../../helpers/held_provider_read.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  for (final variant in [
    (
      kind: RoutineKind.weekdays,
      label: 'Selected weekdays',
      locale: 'en',
      scale: 1.0,
    ),
    (
      kind: RoutineKind.interval,
      label: 'Every few days',
      locale: 'en',
      scale: 1.0,
    ),
    (kind: RoutineKind.prn, label: 'As needed', locale: 'en', scale: 1.0),
    (
      kind: RoutineKind.weekdays,
      label: 'Anumite zile ale săptămânii',
      locale: 'ro',
      scale: 2.0,
    ),
  ]) {
    testWidgets(
      'review and save ${variant.kind.name} ${variant.locale} with exact amount from actual form',
      (tester) async {
        if (variant.scale > 1) {
          tester.view.resetPhysicalSize();
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));
        }
        final f = await CareRecordingFixture.create();
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
          const MedicationReview(name: 'Fictional new routine'),
        )).draft;
        final container = await f.workspace.createContainer(
          extraOverrides: [
            deviceTimeZoneProvider.overrideWith(
              (_) async => 'Europe/Bucharest',
            ),
          ],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.db.close();
          container.dispose();
          await tester.pumpAndSettle();
        });
        var saved = false;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: variant.locale == 'ro'
                  ? AppTheme.dark()
                  : AppTheme.light(),
              locale: Locale(variant.locale),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(variant.scale)),
                child: child!,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: RoutineEditor(
                      pillId: draft.medicationId!,
                      amount: MedicationAmount.known('1/2', 'tablet'),
                      onSaved: () => saved = true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('routine-pattern')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(variant.label).last);
        await tester.pumpAndSettle();
        if (variant.kind == RoutineKind.weekdays) {
          for (var d = 1; d <= 7; d++) {
            final finder = find.byKey(ValueKey('weekday-$d'));
            final chip = tester.widget<FilterChip>(finder);
            if (chip.selected != (d == 1 || d == 5)) {
              await tester.tap(finder);
              await tester.pumpAndSettle();
            }
          }
        }
        if (variant.kind == RoutineKind.interval) {
          await tester.enterText(
            find.byKey(const ValueKey('routine-interval')),
            '3',
          );
        }
        // A focused field keeps scrolling its caret back into view; let go
        // of it so the review button stays where ensureVisible puts it.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        final review = find.byKey(const ValueKey('review-routine'));
        await tester.ensureVisible(review);
        await tester.pumpAndSettle();
        await tester.tap(review);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('routine-preview')), findsOneWidget);
        final l = AppLocalizations.of(
          tester.element(find.byType(RoutineEditor)),
        );
        expect(find.text('${l.t08_amount}: 1/2 tablet'), findsOneWidget);
        expect(find.text('Europe/Bucharest'), findsNothing);
        if (variant.kind == RoutineKind.prn) {
          expect(
            find.text(
              'No expected daily doses. Record each use when it happens.',
            ),
            findsOneWidget,
          );
        }
        final save = find.byKey(const ValueKey('save-routine'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(saved, isTrue);
        final versions = await _read(
          tester,
          RoutineRepository(
            database: f.db,
            access: f.workspace.access,
            context: f.workspace.context,
          ).loadForPill(draft.medicationId!),
        );
        final actual = RoutineDefinition.fromJson(
          jsonDecode(versions.single.definitionJson) as Map<String, dynamic>,
        );
        expect(actual.kind, variant.kind);
        expect(actual.timeZone, 'Europe/Bucharest');
        expect(actual.amount.quantityText, '1/2');
        if (variant.kind == RoutineKind.weekdays) {
          expect(actual.weekdays, [1, 5]);
        }
        if (variant.kind == RoutineKind.interval) {
          expect(actual.everyDays, 3);
          expect(actual.anchorDate, isNotNull);
        }
        if (variant.kind == RoutineKind.prn) expect(actual.times, isEmpty);
        expect(
          await _read(tester, f.db.select(f.db.pendingOperations).get()),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'editing a saved routine preserves its zone and complete slot time',
    (tester) async {
      final f = await CareRecordingFixture.create();
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
        const MedicationReview(name: 'Fictional existing routine'),
      )).draft;
      final pillId = draft.medicationId!;
      var editorNow = DateTime.now().toUtc();
      final repository = RoutineRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => editorNow,
      );
      final initial = RoutineDefinition(
        kind: RoutineKind.daily,
        timeZone: 'Europe/Bucharest',
        times: const [RoutineTime(slotId: 'morning', hour: 8, minute: 30)],
        amount: MedicationAmount.known('1', 'tablet'),
      );
      final firstBoundary = _futureMinute(60);
      final localStart = tz.TZDateTime.from(
        firstBoundary,
        tz.getLocation(initial.timeZone),
      );
      final firstPreview = await _read(
        tester,
        repository.preview(
          pillId: pillId,
          routineId: 'saved-routine',
          expectedRevision: 0,
          definition: initial,
          effectiveFrom: firstBoundary,
          fromLocalDate: routineDateKey(localStart),
          throughLocalDate: routineDateKey(
            DateTime.utc(
              localStart.year,
              localStart.month,
              localStart.day + 30,
            ),
          ),
        ),
      );
      await _read(tester, repository.saveReviewed(firstPreview));

      final container = await f.workspace.createContainer(
        extraOverrides: [
          routineRepositoryProvider.overrideWith((ref) async => repository),
          deviceTimeZoneProvider.overrideWith((_) async => 'America/New_York'),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      expect(
        await container.readHeld(deviceTimeZoneProvider),
        'America/New_York',
      );

      var saved = false;
      Future<void> pumpEdit({
        required RoutineDefinition definition,
        required int revision,
        required DateTime boundary,
        required String locale,
      }) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: RoutineEditor(
                      key: ValueKey('edit-$revision'),
                      pillId: pillId,
                      amount: definition.amount,
                      initial: definition,
                      routineId: 'saved-routine',
                      expectedRevision: revision,
                      earliestBoundary: boundary,
                      now: () => editorNow,
                      onSaved: () => saved = true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> reviewAndSave() async {
        // A focused field keeps scrolling its caret back into view; let go
        // of it so the review button stays where ensureVisible puts it.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        final review = find.byKey(const ValueKey('review-routine'));
        await tester.ensureVisible(review);
        await tester.pumpAndSettle();
        await tester.tap(review);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('routine-preview')), findsOneWidget);
        final save = find.byKey(const ValueKey('save-routine'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(saved, isTrue);
        saved = false;
      }

      await pumpEdit(
        definition: initial,
        revision: 1,
        boundary: firstBoundary,
        locale: 'en',
      );
      expect(find.text('Bucharest, Romania'), findsOneWidget);
      // A long edit must not strand Review with an expired automatic boundary.
      editorNow = firstBoundary.add(const Duration(hours: 2));
      await reviewAndSave();
      var versions = await _read(tester, repository.loadForPill(pillId));
      expect(versions.last.effectiveFrom.isAfter(editorNow), isTrue);
      var persisted = RoutineDefinition.fromJson(
        jsonDecode(versions.last.definitionJson) as Map<String, dynamic>,
      );
      expect(persisted.timeZone, 'Europe/Bucharest');
      expect(_slotTimes(persisted), [('morning', 8, 30)]);

      await pumpEdit(
        definition: persisted,
        revision: versions.last.revision,
        boundary: firstBoundary.add(const Duration(hours: 1)),
        locale: 'ro',
      );
      expect(find.text('București, România'), findsOneWidget);
      final l = AppLocalizations.of(tester.element(find.byType(RoutineEditor)));
      await tester.ensureVisible(find.text(l.t09_changeZone));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.t09_changeZone));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'London');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'London · Europe'));
      await tester.pumpAndSettle();
      expect(find.text('London · Europe'), findsOneWidget);
      await reviewAndSave();
      versions = await _read(tester, repository.loadForPill(pillId));
      persisted = RoutineDefinition.fromJson(
        jsonDecode(versions.last.definitionJson) as Map<String, dynamic>,
      );
      expect(persisted.timeZone, 'Europe/London');
      expect(_slotTimes(persisted), [('morning', 8, 30)]);
      expect(tester.takeException(), isNull);
    },
  );
}

DateTime _futureMinute(int minutes) {
  final now = DateTime.now().toUtc();
  final roundedMinute = now.millisecondsSinceEpoch ~/ 60000 + minutes;
  return DateTime.fromMillisecondsSinceEpoch(
    roundedMinute * 60000,
    isUtc: true,
  );
}

List<(String, int, int)> _slotTimes(RoutineDefinition definition) => [
  for (final slot in definition.times) (slot.slotId, slot.hour, slot.minute),
];

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
  if (!done) throw StateError('Database did not settle');
  if (error != null) throw error!;
  return value as T;
}
