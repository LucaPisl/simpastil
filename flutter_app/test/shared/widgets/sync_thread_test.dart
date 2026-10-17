import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_sharing_provider.dart';
import 'package:simpastil/core/medication/care_sharing_status.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/sync_thread.dart';

CareSharingStatus _sharing({
  bool local = false,
  int pending = 0,
  int review = 0,
  bool received = true,
}) => CareSharingStatus(
  isLocalOnly: local,
  lastCarePullAt: received ? DateTime.utc(2026, 10, 13, 6) : null,
  pendingCount: pending,
  needsReviewCount: review,
  uncertainCount: 0,
);

class _Phases extends SyncStatusNotifier {
  @override
  SyncStatus build() => const SyncStatus();
  void go(SyncPhase phase) => state = SyncStatus(phase: phase);
}

void main() {
  group('syncThreadLook', () {
    SyncThreadKind kind(
      CareSharingStatus? sharing, [
      SyncPhase phase = SyncPhase.idle,
      bool watching = false,
      bool settling = false,
      bool faltered = false,
    ]) => syncThreadLook(
      sharing: sharing,
      phase: phase,
      watching: watching,
      settling: settling,
      faltered: faltered,
    ).kind;

    test('a local workspace never shows a thread', () {
      expect(
        kind(_sharing(local: true, pending: 3), SyncPhase.syncing, true),
        SyncThreadKind.hidden,
      );
      expect(kind(null), SyncThreadKind.hidden);
    });

    test('records needing review are not drawn as sync', () {
      expect(
        kind(_sharing(review: 1, pending: 2), SyncPhase.syncing),
        SyncThreadKind.attention,
      );
    });

    test('a background sync with nothing waiting stays out of the way', () {
      expect(kind(_sharing(), SyncPhase.syncing), SyncThreadKind.hidden);
      expect(
        kind(_sharing(), SyncPhase.syncing, true),
        SyncThreadKind.receiving,
      );
      expect(
        kind(_sharing(received: false), SyncPhase.syncing),
        SyncThreadKind.receiving,
      );
    });

    test('waiting changes are carried, and kept when an attempt fails', () {
      final waiting = syncThreadLook(
        sharing: _sharing(pending: 2),
        phase: SyncPhase.idle,
      );
      expect(waiting, const SyncThreadLook(SyncThreadKind.waiting, count: 2));
      expect(
        kind(_sharing(pending: 2), SyncPhase.syncing),
        SyncThreadKind.sending,
      );
      expect(
        syncThreadLook(sharing: _sharing(pending: 2), phase: SyncPhase.failure),
        const SyncThreadLook(SyncThreadKind.broken, count: 2),
      );
    });

    test('a failure with nothing waiting shows only when it was watched', () {
      expect(kind(_sharing(), SyncPhase.failure), SyncThreadKind.hidden);
      expect(
        kind(_sharing(), SyncPhase.failure, false, false, true),
        SyncThreadKind.broken,
      );
    });

    test('settling shows only once nothing is waiting', () {
      expect(
        kind(_sharing(), SyncPhase.idle, false, true),
        SyncThreadKind.settled,
      );
      expect(
        kind(_sharing(pending: 1), SyncPhase.idle, false, true),
        SyncThreadKind.waiting,
      );
      expect(kind(_sharing(received: false)), SyncThreadKind.unverified);
      expect(kind(_sharing()), SyncThreadKind.hidden);
    });
  });

  group('SyncThreadSummary', () {
    late StreamController<CareSharingStatus> sharing;
    late _Phases phases;
    late ValueNotifier<bool> refreshing;

    Future<void> pump(
      WidgetTester tester,
      CareSharingStatus first, {
      bool quiet = false,
    }) async {
      sharing = StreamController<CareSharingStatus>.broadcast();
      refreshing = ValueNotifier(false);
      addTearDown(sharing.close);
      addTearDown(refreshing.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            careSharingStatusProvider.overrideWith((_) async* {
              yield first;
              yield* sharing.stream;
            }),
            syncStatusProvider.overrideWith(() => phases = _Phases()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: quiet),
              child: Scaffold(
                body: Column(
                  children: [
                    SyncThreadSummary(refreshing: refreshing, onOpen: () {}),
                    const Text('below', key: ValueKey('below')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double belowTop(WidgetTester tester) =>
        tester.getTopLeft(find.byKey(const ValueKey('below'))).dy;

    testWidgets('a background sync does not move the day', (tester) async {
      await pump(tester, _sharing());
      final top = belowTop(tester);
      phases.go(SyncPhase.syncing);
      await tester.pump(const Duration(milliseconds: 200));
      expect(belowTop(tester), top);
      expect(find.byKey(const ValueKey('sync-thread')), findsNothing);
      phases.go(SyncPhase.idle);
      await tester.pumpAndSettle();
      expect(belowTop(tester), top);
    });

    testWidgets('a pull shows the sync, settles taut, then folds away', (
      tester,
    ) async {
      await pump(tester, _sharing());
      final top = belowTop(tester);
      refreshing.value = true;
      phases.go(SyncPhase.syncing);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Receiving server updates…'), findsOneWidget);
      expect(belowTop(tester), greaterThan(top));

      refreshing.value = false;
      phases.go(SyncPhase.idle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('Up to date with your server'), findsOneWidget);

      await tester.pump(SyncThreadSummary.settleHold);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sync-thread')), findsNothing);
      expect(belowTop(tester), top);
    });

    testWidgets('waiting changes travel, and the thread rests when sent', (
      tester,
    ) async {
      await pump(tester, _sharing(pending: 2));
      expect(
        find.text('Changes saved on this phone · Waiting to sync'),
        findsOneWidget,
      );
      // At rest nothing animates.
      expect(tester.binding.hasScheduledFrame, isFalse);

      phases.go(SyncPhase.syncing);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Sending changes to your server…'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isTrue);

      sharing.add(_sharing());
      phases.go(SyncPhase.idle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('Up to date with your server'), findsOneWidget);
      await tester.pump(SyncThreadSummary.settleHold);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sync-thread')), findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a watched failure says so, keeps waiting changes, and stays', (
      tester,
    ) async {
      await pump(tester, _sharing(pending: 1));
      phases.go(SyncPhase.syncing);
      await tester.pump(const Duration(milliseconds: 300));
      phases.go(SyncPhase.failure);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        find.text('The last sync didn’t finish · Changes stay on this phone'),
        findsOneWidget,
      );
      // The changes are still waiting, so the thread stays after the moment.
      await tester.pump(SyncThreadSummary.falterHold);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sync-thread')), findsOneWidget);
    });

    testWidgets('a watched failure with nothing waiting folds after a while', (
      tester,
    ) async {
      await pump(tester, _sharing());
      refreshing.value = true;
      phases.go(SyncPhase.syncing);
      await tester.pump(const Duration(milliseconds: 300));
      refreshing.value = false;
      phases.go(SyncPhase.failure);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        find.text('The last sync didn’t finish · Open Sync'),
        findsOneWidget,
      );
      await tester.pump(SyncThreadSummary.falterHold);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sync-thread')), findsNothing);
    });

    testWidgets('quiet motion carries the changes without a running ticker', (
      tester,
    ) async {
      await pump(tester, _sharing(pending: 2), quiet: true);
      phases.go(SyncPhase.syncing);
      await tester.pump();
      expect(find.text('Sending changes to your server…'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });
}
