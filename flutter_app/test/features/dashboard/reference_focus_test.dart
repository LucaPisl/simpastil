import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final locale in ['en', 'ro']) {
    testWidgets(
      'three-dose strip keeps real cards and actions readable $locale',
      (tester) async {
        tester.view.physicalSize = const Size(411, 914);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = await CareRecordingFixture.create(
          routineAmount: MedicationAmount.known('1', 'tablet'),
        );
        await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
            .write(const PillsCompanion(name: Value('Demo Morning')));
        await (f.db.update(f.db.profiles)
              ..where((p) => p.id.equals(f.person.id)))
            .write(const ProfilesCompanion(name: Value('Alex')));
        final setup = SetupRepository(
          database: f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        );
        final routines = RoutineRepository(
          database: f.db,
          access: f.workspace.access,
          context: f.workspace.context,
          clock: () => DateTime.utc(2026, 9, 30, 8),
        );
        for (final item in [
          (name: 'Demo Midday', hour: 13),
          (name: 'Demo Evening', hour: 20),
        ]) {
          var draft = await setup.resumeOrCreateDraft(
            purpose: SetupPurpose.medication,
            fixedPersonId: f.person.id,
          );
          draft = (await setup.saveMedication(
            draft.id,
            draft.revision,
            MedicationReview(name: item.name),
          )).draft;
          await routines.saveReviewed(
            await routines.preview(
              pillId: draft.medicationId!,
              expectedRevision: 0,
              definition: RoutineDefinition(
                kind: RoutineKind.daily,
                timeZone: 'UTC',
                amount: MedicationAmount.known('1', 'tablet'),
                times: [
                  RoutineTime(slotId: item.name, hour: item.hour, minute: 0),
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
        final container = await f.workspace.createContainer(
          extraOverrides: [
            deviceTimeZoneProvider.overrideWith((ref) async => 'UTC'),
          ],
        );
        addTearDown(() async {
          await f.db.close();
          container.dispose();
          await tester.pumpAndSettle();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: const EdgeInsets.only(top: 24, bottom: 24)),
                child: child!,
              ),
              home: const Scaffold(
                body: FocusTodayScreen(),
                bottomNavigationBar: SizedBox(
                  key: ValueKey('native-navigation-boundary'),
                  height: 94,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final boundary = tester
            .getTopLeft(
              find.byKey(const ValueKey('native-navigation-boundary')),
            )
            .dy;
        for (final label
            in locale == 'ro'
                ? ['Luat acum', 'Detaliile dozei', 'Selectează doze']
                : ['Taken now', 'Dose details', 'Select doses']) {
          final target = find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          );
          expect(
            target.hitTestable(),
            findsOneWidget,
            reason: '$label must be reachable without initial scrolling',
          );
          expect(
            tester.getBottomRight(target.hitTestable()).dy,
            lessThan(boundary),
            reason: '$label must not be clipped by navigation',
          );
        }
        final peek = find.byKey(const ValueKey('focus-next-peek'));
        final current = find.byKey(const ValueKey('focus-current-card'));
        expect(tester.getSize(peek).width, tester.getSize(current).width);
        expect(
          tester.getRect(peek).right,
          greaterThan(tester.view.physicalSize.width),
        );
        // The neighbour is the actual full card, not a separately rendered
        // miniature. Selecting it brings all its text into the same anchor.
        final anchor = tester.getTopLeft(current).dx;
        await tester.tapAt(tester.getTopLeft(peek) + const Offset(12, 50));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(current).dx, closeTo(anchor, .5));
        expect(
          find.descendant(of: current, matching: find.text('Demo Midday')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: current,
            matching: find.text(locale == 'ro' ? '13:00' : '1:00 PM'),
          ),
          findsOneWidget,
        );
        // A foreground return invalidates Drift reads after headless work.
        // It must not reset a person's position in the medication strip.
        f.db.refreshExternalChanges();
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: current, matching: find.text('Demo Midday')),
          findsOneWidget,
          reason: 'The selected medication survives external-change refresh',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
