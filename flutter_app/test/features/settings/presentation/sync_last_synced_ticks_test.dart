import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/medication/care_sharing_provider.dart';
import 'package:simpastil/core/medication/care_sharing_status.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';
import 'package:simpastil/features/settings/presentation/sync_recovery_screen.dart';
import 'package:simpastil/features/settings/presentation/sync_settings_section.dart';
import 'package:simpastil/l10n/app_localizations.dart';

void main() {
  for (final (name, size, locale, fresh, later) in const [
    ('phone', Size(400, 900), Locale('en'), 'Just now', '3 minutes ago'),
    ('tablet', Size(1100, 900), Locale('en'), 'Just now', '3 minutes ago'),
    (
      'phone in Romanian',
      Size(400, 900),
      Locale('ro'),
      'Chiar acum',
      'acum 3 minute',
    ),
  ]) {
    group('Last synced keeps counting on $name', () {
      late ProviderContainer container;
      late DateTime now;

      Future<void> pump(WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        now = DateTime.now();
        container = ProviderContainer(
          overrides: [
            careSharingStatusProvider.overrideWith(
              (_) => Stream.value(
                const CareSharingStatus(
                  isLocalOnly: false,
                  lastCarePullAt: null,
                  pendingCount: 0,
                  needsReviewCount: 0,
                  uncertainCount: 0,
                ),
              ),
            ),
            keptNotesCountProvider.overrideWith((_) => Future.value(0)),
            migrationIssuesProvider.overrideWith((_) => Stream.value(const [])),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: SyncSettingsSection(now: () => now),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(
          () => container
              .read(syncStatusProvider.notifier)
              .markSuccess(pendingCount: 0),
        );
        await tester.pump(const Duration(seconds: 1));
      }

      testWidgets('the relative time moves on by itself', (tester) async {
        await pump(tester);
        expect(find.textContaining(fresh), findsWidgets);

        // Three minutes go by with the page left open and nothing else
        // happening: no sync, no navigation.
        now = now.add(const Duration(minutes: 3, seconds: 30));
        await tester.pump(const Duration(minutes: 1));

        expect(find.textContaining(fresh), findsNothing);
        expect(find.textContaining(later), findsWidgets);
      });

      testWidgets('it stops while the app is in the background', (
        tester,
      ) async {
        await pump(tester);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        now = now.add(const Duration(minutes: 3, seconds: 30));
        await tester.pump(const Duration(minutes: 2));
        expect(find.textContaining(fresh), findsWidgets);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(minutes: 1));
        expect(find.textContaining(later), findsWidgets);
      });

      testWidgets('leaving the page leaves no timer behind', (tester) async {
        await pump(tester);
        await tester.pumpWidget(const SizedBox());
        // A pending periodic timer would fail the test at teardown, and
        // advancing time must not touch the disposed state.
        await tester.pump(const Duration(minutes: 5));
        expect(tester.takeException(), isNull);
      });
    });
  }
}
