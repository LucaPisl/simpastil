import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/diagnostics/diagnostics_session.dart';
import 'package:simpastil/features/report/crash_notice_card.dart';
import 'package:simpastil/features/report/report_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _FakeSession extends DiagnosticsSession {
  _FakeSession(this.incident);

  CrashIncident? incident;
  int dismissals = 0;
  bool dismissFails = false;

  @override
  Future<CrashIncident?> pendingIncident() async => incident;

  @override
  Future<void> dismissIncident() async {
    dismissals++;
    if (dismissFails) throw StateError('disk full');
    incident = null;
  }
}

Future<void> _pump(
  WidgetTester tester,
  Size size,
  _FakeSession session, {
  Locale? locale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [diagnosticsSessionProvider.overrideWithValue(session)],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: CrashNoticeCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _incident = CrashIncident(at: DateTime.utc(2026, 10, 18, 9));

void main() {
  for (final entry in {
    'phone': const Size(390, 800),
    'tablet': const Size(900, 1200),
  }.entries) {
    testWidgets('announces an unclean ending on a ${entry.key}', (
      tester,
    ) async {
      await _pump(tester, entry.value, _FakeSession(_incident));
      expect(
        find.text('Simpastil closed unexpectedly last time'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('crash-notice-report')), findsOneWidget);
    });
  }

  testWidgets('says nothing after a normal ending', (tester) async {
    await _pump(tester, const Size(390, 800), _FakeSession(null));
    expect(find.byKey(const ValueKey('crash-notice-card')), findsNothing);
  });

  testWidgets('closing the card remembers the incident was dealt with', (
    tester,
  ) async {
    final session = _FakeSession(_incident);
    await _pump(tester, const Size(390, 800), session);
    await tester.tap(find.byKey(const ValueKey('crash-notice-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('crash-notice-card')), findsNothing);
    expect(session.dismissals, 1);
  });

  testWidgets('a failure to remember it still hides the card', (tester) async {
    final session = _FakeSession(_incident)..dismissFails = true;
    await _pump(tester, const Size(390, 800), session);
    await tester.tap(find.byKey(const ValueKey('crash-notice-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('crash-notice-card')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Report opens the report and counts as dealt with', (
    tester,
  ) async {
    final session = _FakeSession(_incident);
    await _pump(tester, const Size(390, 800), session);
    await tester.tap(find.byKey(const ValueKey('crash-notice-report')));
    // The report reads the real device, so step the clock instead of settling.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ReportProblemScreen), findsOneWidget);
    expect(session.dismissals, 1);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('reads in Romanian at twice the text size', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(
      tester,
      const Size(360, 800),
      _FakeSession(_incident),
      locale: const Locale('ro'),
    );
    expect(
      find.text('Simpastil s-a închis neașteptat data trecută'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
