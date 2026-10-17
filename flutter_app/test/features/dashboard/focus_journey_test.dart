import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  testWidgets(
    'Focus picker refuses tomorrow and selects past or Today exactly',
    (tester) async {
      final f = await CareRecordingFixture.create();
      final container = await f.workspace.createContainer();
      addTearDown(() async {
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      final today = DateUtils.dateOnly(DateTime.now());
      final yesterday = DateTime(today.year, today.month, today.day - 1);
      final tomorrow = DateTime(today.year, today.month, today.day + 1);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.light(),
            home: const FocusTodayScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.calendar_today_outlined));
      await tester.pumpAndSettle();
      final material = MaterialLocalizations.of(
        tester.element(find.byType(DatePickerDialog)),
      );
      await tester.tap(find.byTooltip(material.inputDateModeButtonLabel));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        DateFormat.yMd('en').format(tomorrow),
      );
      await tester.tap(find.text(material.okButtonLabel));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(find.text(material.dateOutOfRangeLabel), findsOneWidget);
      expect(container.read(selectedDateProvider), today);

      await tester.enterText(
        find.byType(TextField),
        DateFormat.yMd('en').format(yesterday),
      );
      await tester.tap(find.text(material.okButtonLabel));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(container.read(selectedDateProvider), yesterday);
      expect(
        find.text(DateFormat.MMMMEEEEd('en').format(yesterday)),
        findsOneWidget,
      );
      await tester.tap(find.text('Back to today'));
      await tester.pumpAndSettle();
      expect(container.read(selectedDateProvider), today);
      expect(
        find.text(DateFormat.MMMMEEEEd('en').format(today)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  for (final variant in [
    (name: 'EN light', romanian: false, width: 390.0, scale: 1.0),
    (name: 'RO dark large', romanian: true, width: 390.0, scale: 1.6),
    (name: 'EN narrow 200 percent', romanian: false, width: 320.0, scale: 2.0),
  ]) {
    final romanian = variant.romanian;
    testWidgets(
      'three exact Focus cards keep recording and Undo in place ${variant.name}',
      (tester) async {
        tester.view.physicalSize = Size(variant.width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = await CareRecordingFixture.create(
          routineAmount: MedicationAmount.known('1', 'tablet'),
        );
        final setup = SetupRepository(
          database: f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        );
        for (final name in [
          'Fictional long medication name for layout review',
          'Fictional evening medication',
        ]) {
          var draft = await setup.resumeOrCreateDraft(
            purpose: SetupPurpose.medication,
            fixedPersonId: f.person.id,
          );
          draft = (await setup.saveMedication(
            draft.id,
            draft.revision,
            MedicationReview(name: name),
          )).draft;
          final routines = RoutineRepository(
            database: f.db,
            access: f.workspace.access,
            context: f.workspace.context,
            clock: () => DateTime.utc(2026, 9, 30, 8),
          );
          await routines.saveReviewed(
            await routines.preview(
              pillId: draft.medicationId!,
              expectedRevision: 0,
              definition: RoutineDefinition(
                kind: RoutineKind.daily,
                timeZone: 'UTC',
                times: [
                  const RoutineTime(slotId: 'morning', hour: 9, minute: 0),
                ],
              ),
              effectiveFrom: DateTime.utc(2026, 9, 30, 8),
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
        final container = await f.workspace.createContainer();
        addTearDown(() async {
          await f.db.close();
          container.dispose();
          await tester.pumpAndSettle();
        });
        container
            .read(selectedDateProvider.notifier)
            .select(CareRecordingFixture.planned);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: Locale(romanian ? 'ro' : 'en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: romanian ? AppTheme.dark() : AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(variant.scale),
                  disableAnimations: romanian,
                ),
                child: child!,
              ),
              home: const FocusTodayScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final semantics = tester.ensureSemantics();
        try {
          if (variant.scale == 1) {
            final peek = find.byKey(const ValueKey('focus-next-peek'));
            expect(peek, findsOneWidget);
            expect(peek.hitTestable(at: Alignment.centerLeft), findsOneWidget);
            await tester.tapAt(tester.getTopLeft(peek) + const Offset(12, 50));
            await tester.pumpAndSettle();
            expect(find.text('Item 2 of 3'), findsOneWidget);
            final previous = find.byKey(const ValueKey('focus-previous'));
            await tester.ensureVisible(previous);
            await tester.pumpAndSettle();
            await tester.tap(previous);
            await tester.pumpAndSettle();
          }
          if (variant.scale == 2) {
            await tester.scrollUntilVisible(
              find.text('Item 1 of 3'),
              250,
              maxScrolls: 30,
              scrollable: find.byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              ),
            );
            await tester.pumpAndSettle();
          }
          expect(
            find.text(romanian ? 'Elementul 1 din 3' : 'Item 1 of 3'),
            findsOneWidget,
          );
          if (variant.scale == 1) {
            final card = find.byKey(const ValueKey('focus-current-card'));
            await tester.ensureVisible(card);
            final beforeDrag = tester.getTopLeft(card);
            final gesture = await tester.startGesture(tester.getCenter(card));
            await gesture.moveBy(const Offset(-20, 0));
            await tester.pump();
            await gesture.moveBy(const Offset(-160, 0));
            await tester.pump();
            expect(
              tester.getTopLeft(card).dx,
              lessThan(beforeDrag.dx - 150),
              reason: 'cards must follow the finger beyond the old 120px cap',
            );
            await gesture.up();
            await tester.pumpAndSettle();
            expect(find.text('Item 2 of 3'), findsOneWidget);
            expect(
              await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
              isEmpty,
            );
            await tester.drag(
              find.byKey(const ValueKey('focus-current-card')),
              const Offset(220, 0),
            );
            await tester.pumpAndSettle();
            expect(find.text('Item 1 of 3'), findsOneWidget);
          }
          final take = find.byKey(const ValueKey('focus-taken'));
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('focus-current-card')),
              matching: take,
            ),
            findsOneWidget,
          );

          await tester.ensureVisible(take);
          await tester.pumpAndSettle();
          expect(
            find.bySemanticsLabel(romanian ? 'Luat acum' : 'Taken now'),
            findsOneWidget,
          );
          await tester.tap(take);
          await tester.tap(take);
          await tester.pumpAndSettle();
          expect(
            await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
            hasLength(1),
          );
          expect(
            find.text(romanian ? 'Elementul 1 din 3' : 'Item 1 of 3'),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('focus-undo')), findsOneWidget);
          await tester.ensureVisible(find.byKey(const ValueKey('focus-undo')));
          await tester.pumpAndSettle();
          expect(
            find.bySemanticsLabel(romanian ? 'Anulează înregistrarea' : 'Undo'),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('focus-undo')));
          await tester.pumpAndSettle();
          expect(
            await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
            hasLength(2),
          );
          expect(find.byKey(const ValueKey('focus-taken')), findsOneWidget);
          final next = find.byKey(const ValueKey('focus-next'));
          await tester.ensureVisible(next);
          await tester.pumpAndSettle();
          await tester.tap(next);
          await tester.pumpAndSettle();
          expect(
            find.text(romanian ? 'Elementul 2 din 3' : 'Item 2 of 3'),
            findsOneWidget,
          );
          final overview = find.text(
            romanian ? 'Ziua, dintr-o privire' : 'Day overview',
          );
          await tester.ensureVisible(overview);
          await tester.pumpAndSettle();
          await tester.tap(overview);
          await tester.pumpAndSettle();
          final shown = await _read(
            tester,
            container.read(
              careDayProvider(
                const CareDayRequest(localDate: '2026-09-30'),
              ).future,
            ),
          );
          expect(shown.entries, hasLength(3));
          for (final entry in shown.entries) {
            final row = find.byKey(ValueKey('overview-${entry.occurrence.id}'));
            await tester.scrollUntilVisible(
              row,
              140,
              scrollable: find.descendant(
                of: find.byType(DraggableScrollableSheet),
                matching: find.byType(Scrollable),
              ),
            );
            await tester.pumpAndSettle();
            expect(row.hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          semantics.dispose();
        }
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
