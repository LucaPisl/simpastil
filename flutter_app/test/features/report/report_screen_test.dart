import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/diagnostics/report/diagnostic_report.dart';
import 'package:simpastil/core/diagnostics/report/report_channel.dart';
import 'package:simpastil/features/report/report_actions.dart';
import 'package:simpastil/features/report/report_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _FakeActions extends ReportActions {
  _FakeActions({
    this.save = const ReportSaveResult(
      ReportSaveStatus.saved,
      name: 'simpastil-report-20261018-14.txt',
    ),
    this.github = true,
  });

  ReportSaveResult save;
  ReportEmailStatus email = ReportEmailStatus.opened;
  bool github;
  bool share = true;
  final calls = <String>[];

  @override
  Future<ReportSaveResult> saveToDownloads(DiagnosticReport report) async {
    calls.add('save ${report.fileName}');
    return save;
  }

  @override
  Future<ReportEmailStatus> emailMaintainer(
    DiagnosticReport report, {
    required String chooserTitle,
  }) async {
    calls.add('email');
    return email;
  }

  @override
  Future<bool> openGitHub(DiagnosticReport report) async {
    calls.add('github');
    return github;
  }

  @override
  Future<bool> shareWithApp(DiagnosticReport report) async {
    calls.add('share');
    return share;
  }
}

DiagnosticReport _report() => DiagnosticReport(
  createdAt: DateTime.utc(2026, 10, 18, 14, 37),
  app: ReportApp(version: '1.0.0', build: 3, database: 18, language: 'en'),
  lastStop: 'EXIT_CRASH',
);

Future<void> _pump(
  WidgetTester tester,
  Size size,
  _FakeActions actions, {
  Future<DiagnosticReport> Function()? collect,
  Locale? locale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ReportProblemScreen(
        collect: collect ?? () async => _report(),
        actions: actions,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const phone = Size(390, 844);
  const tablet = Size(1000, 1300);

  for (final entry in {'phone': phone, 'tablet': tablet}.entries) {
    group('on a ${entry.key}', () {
      testWidgets('shows both ways to report and nothing is sent yet', (
        tester,
      ) async {
        final actions = _FakeActions();
        await _pump(tester, entry.value, actions);
        expect(find.text('Report a problem'), findsOneWidget);
        expect(find.text('Submit issue on GitHub'), findsOneWidget);
        expect(find.text('Share another way'), findsOneWidget);
        await tester.dragUntilVisible(
          find.textContaining('Never included'),
          find.byType(ListView),
          const Offset(0, -200),
        );
        expect(find.textContaining('Never included'), findsOneWidget);
        expect(actions.calls, isEmpty);
      });

      testWidgets('the preview is exactly the text that is shared', (
        tester,
      ) async {
        await _pump(tester, entry.value, _FakeActions());
        await tester.dragUntilVisible(
          find.byKey(const ValueKey('report-preview')),
          find.byType(ListView),
          const Offset(0, -200),
        );
        await tester.tap(find.byKey(const ValueKey('report-preview')));
        await tester.pumpAndSettle();
        expect(find.textContaining('format: simpastil-report-v1'), findsOne);
        expect(find.textContaining('reason: EXIT_CRASH'), findsOneWidget);
      });

      testWidgets('GitHub: explains the steps, saves, then opens GitHub', (
        tester,
      ) async {
        final actions = _FakeActions();
        await _pump(tester, entry.value, actions);
        await tester.tap(find.byKey(const ValueKey('report-github')));
        await tester.pumpAndSettle();
        expect(find.text('How reporting on GitHub works'), findsOneWidget);
        expect(
          find.textContaining(
            'saved to your Downloads folder as simpastil-report-20261018-14.txt',
          ),
          findsOneWidget,
        );
        expect(actions.calls, isEmpty, reason: 'nothing happens before Save');
        await tester.tap(find.byKey(const ValueKey('report-github-continue')));
        await tester.pumpAndSettle();
        expect(actions.calls, [
          'save simpastil-report-20261018-14.txt',
          'github',
        ]);
        expect(
          find.text('Saved to Downloads as simpastil-report-20261018-14.txt'),
          findsOneWidget,
        );
      });

      testWidgets('GitHub: cancelling the steps does nothing', (tester) async {
        final actions = _FakeActions();
        await _pump(tester, entry.value, actions);
        await tester.tap(find.byKey(const ValueKey('report-github')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(actions.calls, isEmpty);
        expect(find.byKey(const ValueKey('report-status')), findsNothing);
      });

      testWidgets('GitHub: says so when it could not be opened', (
        tester,
      ) async {
        final actions = _FakeActions(github: false);
        await _pump(tester, entry.value, actions);
        await tester.tap(find.byKey(const ValueKey('report-github')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('report-github-continue')));
        await tester.pumpAndSettle();
        expect(find.textContaining('GitHub could not be opened'), findsOne);
        expect(find.textContaining('Saved to Downloads as'), findsOneWidget);
      });

      testWidgets('Share another way offers save, email and other apps', (
        tester,
      ) async {
        final actions = _FakeActions();
        await _pump(tester, entry.value, actions);
        await tester.tap(find.byKey(const ValueKey('report-share')));
        await tester.pumpAndSettle();
        expect(find.text('Save to Downloads'), findsOneWidget);
        expect(find.text('Email the maintainer'), findsOneWidget);
        expect(find.text('Share with another app'), findsOneWidget);
      });

      testWidgets('saving says explicitly where the file went', (tester) async {
        final actions = _FakeActions();
        await _pump(tester, entry.value, actions);
        await tester.tap(find.byKey(const ValueKey('report-share')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('report-save')));
        await tester.pumpAndSettle();
        expect(actions.calls, ['save simpastil-report-20261018-14.txt']);
        expect(
          find.text('Saved to Downloads as simpastil-report-20261018-14.txt'),
          findsOneWidget,
        );
      });

      testWidgets('an Android that cannot save to Downloads explains it', (
        tester,
      ) async {
        final actions = _FakeActions(
          save: const ReportSaveResult(ReportSaveStatus.unsupported),
        );
        await _pump(tester, entry.value, actions);
        await tester.tap(find.byKey(const ValueKey('report-share')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('report-save')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('cannot save straight to Downloads'),
          findsOneWidget,
        );
      });

      testWidgets('email opens the email app; no app is explained', (
        tester,
      ) async {
        final actions = _FakeActions();
        await _pump(tester, entry.value, actions);
        await tester.tap(find.byKey(const ValueKey('report-share')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('report-email')));
        await tester.pumpAndSettle();
        expect(actions.calls, ['email']);
        expect(find.byKey(const ValueKey('report-status')), findsNothing);

        actions.email = ReportEmailStatus.noEmailApp;
        await tester.tap(find.byKey(const ValueKey('report-share')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('report-email')));
        await tester.pumpAndSettle();
        expect(find.textContaining('No email app was found'), findsOneWidget);
      });

      testWidgets('sharing with another app uses the same report', (
        tester,
      ) async {
        final actions = _FakeActions();
        await _pump(tester, entry.value, actions);
        await tester.tap(find.byKey(const ValueKey('report-share')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('report-share-app')));
        await tester.pumpAndSettle();
        expect(actions.calls, ['share']);
      });
    });
  }

  testWidgets('buttons wait until the report has been prepared', (
    tester,
  ) async {
    final pending = Completer<DiagnosticReport>();
    final actions = _FakeActions();
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ReportProblemScreen(
          collect: () => pending.future,
          actions: actions,
        ),
      ),
    );
    await tester.pump();
    final github = tester.widget<FilledButton>(
      find.byKey(const ValueKey('report-github')),
    );
    expect(github.onPressed, isNull);
    pending.complete(_report());
    await tester.pumpAndSettle();
    final ready = tester.widget<FilledButton>(
      find.byKey(const ValueKey('report-github')),
    );
    expect(ready.onPressed, isNotNull);
  });

  testWidgets('works in Romanian', (tester) async {
    await _pump(tester, phone, _FakeActions(), locale: const Locale('ro'));
    expect(find.text('Raportează o problemă'), findsOneWidget);
    expect(find.text('Trimite o problemă pe GitHub'), findsOneWidget);
    expect(find.text('Trimite în alt fel'), findsOneWidget);
  });

  testWidgets('large text does not overflow the sheets', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, phone, _FakeActions());
    await tester.tap(find.byKey(const ValueKey('report-github')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
