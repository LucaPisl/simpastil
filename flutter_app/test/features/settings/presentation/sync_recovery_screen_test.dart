import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_recovery_service.dart';
import 'package:simpastil/core/sync/sync_retry_policy.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/presentation/sync_recovery_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _Service extends Mock implements SyncRecoveryService {}

RecoveryOperation _op(
  RecoveryReason reason, {
  RecoveryChange change = RecoveryChange.edited,
  String state = 'blocked',
  String? code,
  bool serverWon = false,
}) => RecoveryOperation(
  id: 'op',
  component: 'stable',
  change: change,
  reason: reason,
  state: state,
  attemptCount: 1,
  safeErrorCode: code,
  serverAlreadyWon: serverWon,
);

RecoveryItem _item({
  String key = 'person:p1',
  RecoveryItemKind kind = RecoveryItemKind.person,
  String? name = 'Ana',
  RecoveryReason reason = RecoveryReason.blocked,
  List<RecoveryOperation>? operations,
  bool canRetry = false,
  bool canUseServer = false,
  bool historyBlocked = false,
  bool canKeepMine = false,
  bool canDismiss = false,
  bool review = false,
  bool serverDeleted = false,
  bool canTryAgain = false,
  bool canDiscard = false,
  int discardCount = 0,
}) => RecoveryItem(
  key: key,
  kind: kind,
  name: name,
  operations: operations ?? [_op(reason)],
  reason: reason,
  canRetry: canRetry,
  canUseServerVersion: canUseServer,
  discardBlockedByHistory: historyBlocked,
  canKeepMine: canKeepMine,
  canDismiss: canDismiss,
  needsMedicationReview: review,
  serverDeleted: serverDeleted,
  canTryAgain: canTryAgain,
  canDiscard: canDiscard,
  discardCount: discardCount,
);

RecoveryReport _doseReport() => RecoveryReport(
  counts: const SyncOperationCounts(blocked: 1),
  items: [
    _item(
      kind: RecoveryItemKind.dose,
      name: 'Aspirin',
      key: 'dose:o1',
      reason: RecoveryReason.blocked,
      operations: [_op(RecoveryReason.blocked, change: RecoveryChange.dose)],
      review: true,
      canUseServer: true,
      canTryAgain: true,
      canDiscard: true,
    ),
  ],
);

void main() {
  late _Service service;

  setUp(() {
    service = _Service();
    PackageInfo.setMockInitialValues(
      appName: 'Simpastil',
      packageName: 'invalid.test',
      version: '9.9.9',
      buildNumber: '99',
      buildSignature: '',
    );
    when(
      () => service.buildDiagnostics(
        any(),
        capabilities: any(named: 'capabilities'),
        appVersion: any(named: 'appVersion'),
      ),
    ).thenAnswer((_) async => 'DIAGNOSTIC TEXT');
  });

  Future<void> pump(
    WidgetTester tester,
    RecoveryReport report, {
    Locale locale = const Locale('en'),
  }) async {
    when(() => service.diagnose(any())).thenAnswer((_) async => report);
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncRecoveryServiceProvider.overrideWithValue(service),
          currentUserIdProvider.overrideWithValue('user-1'),
          recoveryCapabilitiesLoaderProvider.overrideWithValue(
            () async => null,
          ),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SyncRecoveryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('nothing to fix says so and offers no retry', (tester) async {
    await pump(tester, RecoveryReport.empty);

    expect(find.byKey(const ValueKey('recovery-nothing')), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-retry-all')), findsNothing);
    // The two tools stay available.
    expect(find.byKey(const ValueKey('recovery-redownload')), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-copy')), findsOneWidget);
  });

  testWidgets('a blocked item explains itself without raw ids', (tester) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(blocked: 1),
        items: [
          _item(
            canRetry: true,
            canUseServer: true,
            operations: [
              _op(
                RecoveryReason.blocked,
                code: SyncRetryPolicy.bodyChangedCode,
              ),
            ],
          ),
        ],
      ),
    );

    expect(find.text('Ana'), findsOneWidget);
    expect(find.text("Can't be sent as it is."), findsOneWidget);
    expect(
      find.textContaining('edited after the first attempt'),
      findsOneWidget,
    );
    expect(find.textContaining('STABLE_REQUEST_BODY_CHANGED'), findsNothing);
    expect(find.textContaining('p1'), findsNothing);
    expect(find.byKey(const ValueKey('recovery-retry-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-use-server')), findsOneWidget);
  });

  testWidgets('Retry all runs the retry', (tester) async {
    when(
      () => service.retryAll(any()),
    ).thenAnswer((_) async => const RecoveryOutcome(affected: 1));
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(blocked: 1),
        items: [_item(canRetry: true)],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('recovery-retry-all')));
    await tester.pumpAndSettle();

    verify(() => service.retryAll('user-1')).called(1);
    expect(find.textContaining('Tried again'), findsOneWidget);
  });

  testWidgets('Use server version asks first, then discards', (tester) async {
    when(
      () => service.useServerVersion(any(), any()),
    ).thenAnswer((_) async => const RecoveryOutcome(affected: 1));
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(conflict: 1),
        items: [
          _item(
            reason: RecoveryReason.conflict,
            operations: [_op(RecoveryReason.conflict, state: 'conflict')],
            canUseServer: true,
            canKeepMine: true,
          ),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('recovery-use-server')));
    await tester.pumpAndSettle();
    expect(find.text("Use the server's version?"), findsOneWidget);
    verifyNever(() => service.useServerVersion(any(), any()));

    await tester.tap(find.widgetWithText(FilledButton, 'Use server version'));
    await tester.pumpAndSettle();
    verify(() => service.useServerVersion('user-1', 'person:p1')).called(1);
  });

  for (final (outcome, text) in [
    (
      const RecoveryOutcome(serverCopyPending: true),
      "Your change was dropped. The server's version is waiting to download and will replace it at the next sync.",
    ),
    (
      const RecoveryOutcome(refusal: RecoveryRefusal.offline),
      "The server can't be reached right now, so your change was kept. Try again when you are online.",
    ),
    (
      const RecoveryOutcome(busy: true),
      'A sync is already running. Try again in a moment.',
    ),
  ]) {
    testWidgets('Use server version says "$text"', (tester) async {
      when(
        () => service.useServerVersion(any(), any()),
      ).thenAnswer((_) async => outcome);
      await pump(
        tester,
        RecoveryReport(
          counts: const SyncOperationCounts(conflict: 1),
          items: [
            _item(
              reason: RecoveryReason.conflict,
              operations: [_op(RecoveryReason.conflict, state: 'conflict')],
              canUseServer: true,
            ),
          ],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('recovery-use-server')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Use server version'));
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
    });
  }

  testWidgets('an item deleted on the server says so and offers only the '
      'server version', (tester) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(conflict: 1),
        items: [
          _item(
            reason: RecoveryReason.conflict,
            operations: [_op(RecoveryReason.conflict, state: 'conflict')],
            canUseServer: true,
            serverDeleted: true,
          ),
        ],
      ),
    );

    expect(
      find.text(
        "It was deleted on the server, so your change can't be applied. "
        "Use the server's version to accept the deletion.",
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('recovery-use-server')), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-keep-mine')), findsNothing);
  });

  testWidgets('cancelling the confirmation changes nothing', (tester) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(conflict: 1),
        items: [
          _item(
            reason: RecoveryReason.conflict,
            operations: [_op(RecoveryReason.conflict, state: 'conflict')],
            canUseServer: true,
          ),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('recovery-use-server')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    verifyNever(() => service.useServerVersion(any(), any()));
  });

  testWidgets('a conflict the server already won offers one-tap Dismiss', (
    tester,
  ) async {
    when(
      () => service.dismiss(any(), any()),
    ).thenAnswer((_) async => const RecoveryOutcome(affected: 1));
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(conflict: 1),
        items: [
          _item(
            reason: RecoveryReason.conflict,
            operations: [
              _op(RecoveryReason.conflict, state: 'conflict', serverWon: true),
            ],
            canDismiss: true,
            canKeepMine: true,
          ),
        ],
      ),
    );

    expect(find.textContaining('already showing here'), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-use-server')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('recovery-dismiss')));
    await tester.pumpAndSettle();
    verify(() => service.dismiss('user-1', 'person:p1')).called(1);
  });

  testWidgets('a stranded change says what it waits for', (tester) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(stranded: 1),
        items: [
          _item(
            kind: RecoveryItemKind.medication,
            name: 'Aspirin',
            key: 'medication:m1',
            reason: RecoveryReason.stranded,
            operations: [
              _op(
                RecoveryReason.stranded,
                change: RecoveryChange.added,
                state: 'queued',
              ),
            ],
          ),
        ],
      ),
    );
    expect(find.text('Aspirin'), findsOneWidget);
    expect(
      find.text('Waiting for another change that is stuck.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('recovery-use-server')), findsNothing);
  });

  testWidgets('a create with dose history shows a disabled discard', (
    tester,
  ) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(blocked: 1),
        items: [
          _item(
            kind: RecoveryItemKind.medication,
            name: 'Aspirin',
            key: 'medication:m1',
            operations: [
              _op(RecoveryReason.blocked, change: RecoveryChange.added),
            ],
            historyBlocked: true,
            canRetry: true,
          ),
        ],
      ),
    );

    final disabled = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('recovery-use-server-disabled')),
    );
    expect(disabled.onPressed, isNull);
    expect(find.byKey(const ValueKey('recovery-history-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-use-server')), findsNothing);
  });

  testWidgets('a retrying change shows only waiting, no fix buttons', (
    tester,
  ) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(retrying: 1),
        items: [
          _item(
            reason: RecoveryReason.retrying,
            operations: [
              _op(RecoveryReason.retrying, state: 'failedRetryable'),
            ],
            canRetry: true,
          ),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('recovery-waiting-only')), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-use-server')), findsNothing);
  });

  testWidgets('a medication-ledger conflict has real actions and no dead '
      '"Open review" button', (tester) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(conflict: 1),
        items: [
          _item(
            kind: RecoveryItemKind.dose,
            name: 'Aspirin',
            key: 'dose:o1',
            reason: RecoveryReason.conflict,
            operations: [
              _op(
                RecoveryReason.conflict,
                change: RecoveryChange.dose,
                state: 'conflict',
              ),
            ],
            review: true,
            canUseServer: true,
            canTryAgain: true,
            canDiscard: true,
          ),
        ],
      ),
    );
    expect(find.text('Open review'), findsNothing);
    expect(find.byKey(const ValueKey('recovery-use-server')), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-try-again')), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-discard')), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-dismiss')), findsNothing);
  });

  testWidgets('a dose item: Try again runs without asking', (tester) async {
    when(
      () => service.tryAgain(any(), any()),
    ).thenAnswer((_) async => const RecoveryOutcome(affected: 1));
    await pump(tester, _doseReport());

    await tester.tap(find.byKey(const ValueKey('recovery-try-again')));
    await tester.pumpAndSettle();

    verify(() => service.tryAgain('user-1', 'dose:o1')).called(1);
    expect(find.textContaining('Tried again'), findsOneWidget);
  });

  testWidgets('a dose item: Discard says plainly what is lost, then discards', (
    tester,
  ) async {
    when(
      () => service.discardItem(any(), any()),
    ).thenAnswer((_) async => const RecoveryOutcome(affected: 1));
    await pump(tester, _doseReport());

    await tester.tap(find.byKey(const ValueKey('recovery-discard')));
    await tester.pumpAndSettle();
    expect(find.text('Discard this change?'), findsOneWidget);
    expect(
      find.textContaining('was never accepted by the server'),
      findsOneWidget,
    );
    expect(find.textContaining("can't be undone"), findsOneWidget);
    verifyNever(() => service.discardItem(any(), any()));

    await tester.tap(find.widgetWithText(FilledButton, 'Discard this change'));
    await tester.pumpAndSettle();

    verify(() => service.discardItem('user-1', 'dose:o1')).called(1);
    expect(find.textContaining('Discarded'), findsOneWidget);
  });

  testWidgets('a discard that drops several changes says how many', (
    tester,
  ) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(blocked: 1),
        items: [
          _item(
            kind: RecoveryItemKind.dose,
            name: 'Aspirin',
            key: 'dose:o1',
            reason: RecoveryReason.blocked,
            operations: [
              _op(RecoveryReason.blocked, change: RecoveryChange.dose),
            ],
            canDiscard: true,
            discardCount: 3,
          ),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('recovery-discard')));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 changes in all'), findsOneWidget);
  });

  testWidgets('a single discarded change does not mention a count', (
    tester,
  ) async {
    await pump(tester, _doseReport());
    await tester.tap(find.byKey(const ValueKey('recovery-discard')));
    await tester.pumpAndSettle();
    expect(find.textContaining('changes in all'), findsNothing);
  });

  testWidgets('cancelling the discard changes nothing', (tester) async {
    await pump(tester, _doseReport());
    await tester.tap(find.byKey(const ValueKey('recovery-discard')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    verifyNever(() => service.discardItem(any(), any()));
  });

  testWidgets('a dose item: Use server version asks, then uses it', (
    tester,
  ) async {
    when(
      () => service.useServerVersion(any(), any()),
    ).thenAnswer((_) async => const RecoveryOutcome(affected: 1));
    await pump(tester, _doseReport());

    await tester.tap(find.byKey(const ValueKey('recovery-use-server')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Use server version'));
    await tester.pumpAndSettle();

    verify(() => service.useServerVersion('user-1', 'dose:o1')).called(1);
  });

  testWidgets('a stock item names the stock in the discard question', (
    tester,
  ) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(blocked: 1),
        items: [
          _item(
            kind: RecoveryItemKind.medication,
            name: 'Aspirin',
            key: 'medication:p1',
            operations: [
              _op(RecoveryReason.blocked, change: RecoveryChange.stock),
            ],
            canTryAgain: true,
            canDiscard: true,
          ),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('recovery-discard')));
    await tester.pumpAndSettle();
    expect(find.textContaining('stock change'), findsOneWidget);
  });

  testWidgets('a kept note can be dismissed', (tester) async {
    when(
      () => service.dismissNote(any(), any()),
    ).thenAnswer((_) async => const RecoveryOutcome(affected: 1));
    await pump(
      tester,
      RecoveryReport(
        counts: SyncOperationCounts.none,
        items: const [],
        notes: [
          RecoveryNote(issueId: 'n1', createdAt: DateTime.utc(2026, 10, 6)),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('recovery-nothing')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('recovery-note-dismiss')));
    await tester.pumpAndSettle();
    verify(() => service.dismissNote('user-1', 'n1')).called(1);
  });

  testWidgets('the Romanian discard confirmation is Romanian', (tester) async {
    await pump(tester, _doseReport(), locale: const Locale('ro'));
    await tester.tap(find.byKey(const ValueKey('recovery-discard')));
    await tester.pumpAndSettle();
    expect(find.text('Renunți la această modificare?'), findsOneWidget);
    expect(
      find.textContaining('nu a fost acceptată de server'),
      findsOneWidget,
    );
  });

  testWidgets('Re-download explains that unsent changes stay', (tester) async {
    when(
      () => service.redownload(any()),
    ).thenAnswer((_) async => const RecoveryOutcome(pulled: true));
    await pump(tester, RecoveryReport.empty);

    await tester.tap(find.byKey(const ValueKey('recovery-redownload')));
    await tester.pumpAndSettle();
    expect(find.textContaining('never overwritten'), findsOneWidget);
    verifyNever(() => service.redownload(any()));

    await tester.tap(
      find.widgetWithText(FilledButton, 'Re-download from server'),
    );
    await tester.pumpAndSettle();
    verify(() => service.redownload('user-1')).called(1);
  });

  testWidgets('Copy diagnostics puts the report on the clipboard', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester, RecoveryReport.empty);

    await tester.tap(find.byKey(const ValueKey('recovery-copy')));
    await tester.pumpAndSettle();

    expect(copied, 'DIAGNOSTIC TEXT');
    expect(find.text('Diagnostics copied'), findsOneWidget);
  });

  testWidgets('renders in Romanian', (tester) async {
    await pump(
      tester,
      RecoveryReport(
        counts: const SyncOperationCounts(blocked: 1),
        items: [_item(canRetry: true, canUseServer: true)],
      ),
      locale: const Locale('ro'),
    );
    expect(find.text('Rezolvă problemele de sincronizare'), findsOneWidget);
    expect(find.text('Reîncearcă toate'), findsOneWidget);
    expect(find.text('Folosește versiunea serverului'), findsOneWidget);
  });
}
