import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/occurrence_detail_provider.dart';
import 'package:simpastil/core/medication/occurrence_detail_repository.dart';
import 'package:simpastil/features/dashboard/dose_detail_screen.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/review_rendering.dart';
import '../../helpers/window_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });
  for (final ro in [false, true]) {
    for (final outcome in [
      CareSharingOutcome.pending,
      CareSharingOutcome.acknowledged,
      CareSharingOutcome.reconciled,
    ]) {
      testWidgets(
        'Focus and detail distinguish ${outcome.name} ${ro ? 'RO' : 'EN'}',
        (tester) async {
          final f = await CareRecordingFixture.create(connected: true);
          final writer = CareRecordingService(
            database: f.db,
            access: f.workspace.access,
            context: f.workspace.context,
          );
          await writer.commit(
            await writer.prepareTakenNow(
              personId: f.person.id,
              occurrenceId: f.occurrence.id,
              expectedStateVersion: 0,
              amount: const MedicationAmount.unknown(),
            ),
          );
          final day = await CareDayRepository(
            database: f.db,
            access: f.workspace.access,
            context: f.workspace.context,
          ).load(localDate: '2026-09-30');
          final original = day.entries.single;
          final projectedDay = CareDay(
            localDate: day.localDate,
            state: day.state,
            people: day.people,
            prn: day.prn,
            entries: [
              CareDayEntry(
                occurrence: original.occurrence,
                person: original.person,
                pill: original.pill,
                snapshot: original.snapshot,
                plannedAmount: original.plannedAmount,
                head: original.head,
                sharing: outcome,
              ),
            ],
          );
          final detail = await OccurrenceDetailRepository(
            database: f.db,
            access: f.workspace.access,
            context: f.workspace.context,
          ).load(f.occurrence.id);
          final projectedDetail = OccurrenceCareDetail(
            occurrence: detail.occurrence,
            snapshot: detail.snapshot,
            personId: detail.personId,
            personName: detail.personName,
            medicationName: detail.medicationName,
            originalDosage: detail.originalDosage,
            currentPerson: detail.currentPerson,
            currentMedication: detail.currentMedication,
            plannedAmount: detail.plannedAmount,
            audit: detail.audit,
            head: detail.head,
            sharing: outcome,
            canRecord: detail.canRecord,
            canUndo: detail.canUndo,
          );
          final container = await f.workspace.createContainer(
            extraOverrides: [
              careDayProvider.overrideWith(
                (ref, request) => Stream.value(projectedDay),
              ),
              occurrenceDetailProvider.overrideWith(
                (ref, id) => Stream.value(projectedDetail),
              ),
            ],
          );
          container
              .read(selectedDateProvider.notifier)
              .select(DateTime(2026, 9, 30));
          useWindow(tester, const Size(412, 914));
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            container.dispose();
            await tester.pumpAndSettle();
            await tester.runAsync(f.db.close);
            await tester.binding.setSurfaceSize(null);
          });
          Widget app(Widget screen) => UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: Locale(ro ? 'ro' : 'en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: reviewRenderingTheme(
                ro ? AppTheme.dark() : AppTheme.light(),
              ),
              builder: (context, child) => RepaintBoundary(
                key: reviewCaptureKey,
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(ro ? 2 : 1)),
                  child: child!,
                ),
              ),
              home: screen,
            ),
          );
          final reviewed = ro
              ? 'Revizuit · trimiterea inițială este neconfirmată'
              : 'Reviewed · original delivery unconfirmed';
          final pending = ro
              ? 'Salvat aici · așteaptă trimiterea'
              : 'Saved here · waiting to share';
          final focusPending = ro
              ? 'Salvat aici · așteaptă partajarea'
              : pending;
          final focusAccepted = ro
              ? 'Acceptat în îngrijirea partajată'
              : 'Accepted by shared care';
          final detailAccepted = ro
              ? 'Înregistrare acceptată de server'
              : 'Shared record accepted';
          for (final focus in [true, false]) {
            await tester.pumpWidget(
              app(
                focus
                    ? const FocusTodayScreen()
                    : DoseDetailScreen(occurrenceId: f.occurrence.id),
              ),
            );
            await tester.pumpAndSettle();
            final expected = outcome == CareSharingOutcome.reconciled
                ? reviewed
                : outcome == CareSharingOutcome.pending
                ? (focus ? focusPending : pending)
                : focus
                ? focusAccepted
                : detailAccepted;
            await tester.scrollUntilVisible(
              find.text(expected).hitTestable(),
              180,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(find.text(expected).hitTestable(), findsOneWidget);
            if (outcome != CareSharingOutcome.acknowledged) {
              expect(find.text(focusAccepted), findsNothing);
              expect(find.text(detailAccepted), findsNothing);
            }
            if (outcome == CareSharingOutcome.reconciled) {
              expect(find.text(pending), findsNothing);
              expect(find.text(focusPending), findsNothing);
              await captureReview(
                tester,
                'reconciled-${focus ? 'focus' : 'detail'}-${ro ? 'ro-large' : 'en'}',
              );
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
        },
      );
    }
  }
}
