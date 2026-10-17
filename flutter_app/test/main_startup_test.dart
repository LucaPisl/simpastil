import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/startup/optional_capability.dart';
import 'package:simpastil/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OptionalCapabilityNotifier', () {
    test(
      'a late error replaces timeout degradation with the actual failure',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(optionalCapabilityProvider.notifier);
        final work = Completer<void>();

        await notifier.initialize(
          id: 'notifications',
          label: 'Notifications',
          operation: () => work.future,
          timeout: const Duration(milliseconds: 10),
        );
        expect(
          container
              .read(optionalCapabilityProvider)
              .capabilities['notifications']
              ?.failureType,
          'TimeoutException',
        );

        work.completeError(StateError('plugin unavailable'));
        await Future<void>.delayed(Duration.zero);

        final status = container
            .read(optionalCapabilityProvider)
            .capabilities['notifications'];
        expect(status?.phase, OptionalCapabilityPhase.degraded);
        expect(status?.failureType, 'StateError');
      },
    );

    test('retries during pending work join one invocation', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(optionalCapabilityProvider.notifier);
      final work = Completer<void>();
      var calls = 0;

      Future<void> operation() {
        calls++;
        return work.future;
      }

      final initial = notifier.initialize(
        id: 'notifications',
        label: 'Notifications',
        operation: operation,
        timeout: const Duration(seconds: 5),
      );
      final firstRetry = notifier.retry('notifications');
      final secondRetry = notifier.retry('notifications');

      expect(calls, 1);
      work.complete();
      await Future.wait([initial, firstRetry, secondRetry]);
      expect(calls, 1);
      expect(
        container.read(optionalCapabilityProvider).isReady('notifications'),
        isTrue,
      );
    });

    test('retry after a settled failure starts a fresh invocation', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(optionalCapabilityProvider.notifier);
      var calls = 0;

      Future<void> operation() {
        calls++;
        if (calls == 1) throw StateError('plugin unavailable');
        return Future<void>.value();
      }

      await notifier.initialize(
        id: 'notifications',
        label: 'Notifications',
        operation: operation,
      );
      expect(calls, 1);
      expect(
        container
            .read(optionalCapabilityProvider)
            .capabilities['notifications']
            ?.failureType,
        'StateError',
      );

      await notifier.retry('notifications');

      expect(calls, 2);
      expect(
        container.read(optionalCapabilityProvider).isReady('notifications'),
        isTrue,
      );
    });

    test('reentrant initialize joins the slot before invoking again', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(optionalCapabilityProvider.notifier);
      final work = Completer<void>();
      var calls = 0;
      late Future<void> reentrant;

      Future<void> operation() {
        calls++;
        reentrant = notifier.initialize(
          id: 'notifications',
          label: 'Notifications',
          operation: () async => calls++,
        );
        return work.future;
      }

      final initial = notifier.initialize(
        id: 'notifications',
        label: 'Notifications',
        operation: operation,
      );

      expect(calls, 1);
      work.complete();
      await Future.wait([initial, reentrant]);
      expect(calls, 1);
      expect(
        container.read(optionalCapabilityProvider).isReady('notifications'),
        isTrue,
      );
    });

    test(
      'a completed operation stays ready after its deadline passes',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(optionalCapabilityProvider.notifier);

        await notifier.initialize(
          id: 'notifications',
          label: 'Notifications',
          operation: () async {},
          timeout: const Duration(milliseconds: 100),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(
          container.read(optionalCapabilityProvider).isReady('notifications'),
          isTrue,
        );
      },
    );

    test(
      'late completion after provider disposal does not publish state',
      () async {
        final observer = _CapabilityObserver();
        final container = ProviderContainer(observers: [observer]);
        final notifier = container.read(optionalCapabilityProvider.notifier);
        final work = Completer<void>();
        final initialize = notifier.initialize(
          id: 'notifications',
          label: 'Notifications',
          operation: () => work.future,
          timeout: const Duration(seconds: 5),
        );

        container.dispose();
        final updatesAtDisposal = observer.updates;
        work.complete();
        await initialize;

        expect(observer.didDispose, isTrue);
        expect(observer.updates, updatesAtDisposal);
      },
    );
  });

  testWidgets(
    'shell renders during startup and retry joins work after timeout',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final neverCompletes = Completer<void>();
      var invocations = 0;

      Future<void> initializeNotifications() async {
        invocations++;
        return neverCompletes.future;
      }

      unawaited(
        container
            .read(optionalCapabilityProvider.notifier)
            .initialize(
              id: 'notifications',
              label: 'Notifications',
              operation: initializeNotifications,
              timeout: const Duration(seconds: 1),
            ),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  OptionalCapabilityBanner(),
                  Expanded(child: Text('Log PRN now')),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Log PRN now'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(invocations, 1);
      expect(container.read(optionalCapabilityProvider).degraded, isEmpty);
      neverCompletes.complete();
      await tester.pumpAndSettle();
      expect(
        container.read(optionalCapabilityProvider).isReady('notifications'),
        isTrue,
      );
      expect(find.text('Log PRN now'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    },
  );
}

class _CapabilityObserver extends ProviderObserver {
  int updates = 0;
  bool didDispose = false;

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    if (provider == optionalCapabilityProvider) updates++;
  }

  @override
  void didDisposeProvider(
    ProviderBase<Object?> provider,
    ProviderContainer container,
  ) {
    if (provider == optionalCapabilityProvider) didDispose = true;
  }
}
