import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/reminder_reconcile_runner.dart';
import 'package:simpastil/features/settings/presentation/reminder_reset_action.dart';
import 'package:simpastil/l10n/app_localizations.dart';

Future<void> _pump(
  WidgetTester tester,
  Future<ReminderResetResult> Function(Locale?) reset, {
  ReminderAuditReport? report,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        reminderResetProvider.overrideWithValue(reset),
        reminderAuditReportProvider.overrideWith((ref) async => report),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ResetRemindersRow()),
      ),
    ),
  );
}

void main() {
  testWidgets('cancel does nothing; confirm resets and reports the count', (
    tester,
  ) async {
    var calls = 0;
    await _pump(tester, (_) async {
      calls++;
      return const ReminderResetResult.success(removed: 4, scheduled: 3);
    });
    await tester.tap(find.byType(ResetRemindersRow));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, 0);

    await tester.tap(find.byType(ResetRemindersRow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-reminders-confirm')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Reminders reset. 3 set again.'), findsOneWidget);
  });

  testWidgets('a failure and a missing permission each say so', (tester) async {
    var failure = ReminderResetFailure.rebuild;
    await _pump(tester, (_) async => ReminderResetResult.failed(failure));
    for (final entry in {
      ReminderResetFailure.rebuild:
          'Reminders could not be reset. Try again in a moment.',
      ReminderResetFailure.permission:
          'Allow notifications and exact alarms first, then reset reminders.',
      ReminderResetFailure.registry:
          'The reminder records on this device could not be read, so nothing was changed. Your medicines and history are safe.',
    }.entries) {
      failure = entry.key;
      await tester.tap(find.byType(ResetRemindersRow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reset-reminders-confirm')));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      ScaffoldMessenger.of(
        tester.element(find.byType(ResetRemindersRow)),
      ).clearSnackBars();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a rebuild still retrying says the reminders are coming back', (
    tester,
  ) async {
    await _pump(
      tester,
      (_) async => const ReminderResetResult.failed(
        ReminderResetFailure.rebuild,
        restoring: true,
      ),
    );
    await tester.tap(find.byType(ResetRemindersRow));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-reminders-confirm')));
    await tester.pumpAndSettle();
    expect(
      find.text('Reminders are being set up again. This can take a moment.'),
      findsOneWidget,
    );
  });

  testWidgets('the last check and what it left out are shown', (tester) async {
    await _pump(
      tester,
      (_) async => const ReminderResetResult.success(removed: 0, scheduled: 0),
      report: ReminderAuditReport(
        at: DateTime.utc(2026, 9, 24, 12),
        ran: true,
        cancelledPending: 2,
        skippedWorkspaces: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Stray reminders removed: 2.'), findsOneWidget);
    expect(find.textContaining('left out this time'), findsOneWidget);
  });
}
