import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/import_plan.dart';
import 'package:simpastil/features/settings/presentation/import_dose_conflict_card.dart';
import 'package:simpastil/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'difference review displays distinct facts and has no apply or recording controls',
    (tester) async {
      const conflict = ImportDoseConflict(
        local: ImportDoseContext(
          personName: 'Fictional Alexandra LongName',
          medicationName: 'Example Tablet',
          localDate: '2026-10-03',
          localTime: '09:00',
          state: ImportDoseState.skipped,
        ),
        imported: ImportDoseContext(
          personName: 'Fictional Alexandra LongName',
          medicationName: 'Example Tablet',
          localDate: '2026-10-03',
          localTime: null,
          state: ImportDoseState.taken,
        ),
      );
      var reviews = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: SingleChildScrollView(
                child: ImportDoseConflictCard(
                  conflict: conflict,
                  onReview: () {
                    reviews++;
                    showDialog<void>(
                      context: context,
                      builder: (_) =>
                          const ImportDoseDifferenceDialog(conflict: conflict),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review difference'));
      await tester.tap(find.text('Review difference'));
      await tester.pumpAndSettle();
      expect(reviews, 1);
      expect(find.text('Skipped'), findsWidgets);
      expect(find.text('Taken'), findsWidgets);
      expect(find.textContaining('Time unknown'), findsWidgets);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.text('Apply reviewed import'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(reviews, 1);
    },
  );
}
