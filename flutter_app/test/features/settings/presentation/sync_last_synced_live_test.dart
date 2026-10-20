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
  for (final (name, size) in const [
    ('phone', Size(400, 900)),
    ('tablet', Size(1100, 900)),
  ]) {
    group('Last synced follows the sync on $name', () {
      late ProviderContainer container;

      Future<void> pump(WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
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
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: SyncSettingsSection(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }

      testWidgets('a sync that finishes while the page is open updates it', (
        tester,
      ) async {
        await pump(tester);
        expect(find.textContaining('Never'), findsOneWidget);

        await tester.runAsync(
          () => container
              .read(syncStatusProvider.notifier)
              .markSuccess(pendingCount: 0),
        );
        await tester.pump(const Duration(seconds: 1));

        expect(find.textContaining('Never'), findsNothing);
        expect(find.textContaining('Just now'), findsWidgets);
      });

      testWidgets('a background sync is picked up when the app returns', (
        tester,
      ) async {
        await pump(tester);
        expect(find.textContaining('Never'), findsOneWidget);

        // The background task records its time in the stored preferences only.
        await tester.runAsync(() async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            'last_sync_at',
            DateTime.now().toIso8601String(),
          );
        });
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(seconds: 1));

        expect(find.textContaining('Never'), findsNothing);
        expect(find.textContaining('Just now'), findsWidgets);
      });
    });
  }
}
