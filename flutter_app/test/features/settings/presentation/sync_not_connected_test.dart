import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/medication/care_sharing_provider.dart';
import 'package:simpastil/core/medication/care_sharing_status.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';
import 'package:simpastil/features/settings/presentation/sync_recovery_screen.dart';
import 'package:simpastil/features/settings/presentation/sync_settings_section.dart';
import 'package:simpastil/l10n/app_localizations.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool localOnly,
    int notes = 0,
    bool notesFail = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          careSharingStatusProvider.overrideWith(
            (_) => Stream.value(
              CareSharingStatus(
                isLocalOnly: localOnly,
                lastCarePullAt: null,
                pendingCount: 0,
                needsReviewCount: 0,
                uncertainCount: 0,
              ),
            ),
          ),
          keptNotesCountProvider.overrideWith(
            (_) => notesFail
                ? Future<int>.error(StateError('x'))
                : Future.value(notes),
          ),
          migrationIssuesProvider.overrideWith((_) => Stream.value(const [])),
        ],
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

  Finder syncButton() => find.widgetWithText(FilledButton, 'Sync now');

  testWidgets('local-only device is told it is not connected', (tester) async {
    await pump(tester, localOnly: true);
    expect(tester.widget<FilledButton>(syncButton()).onPressed, isNull);
    expect(find.text('Not connected to a server'), findsOneWidget);
    expect(find.text('Pull latest data from server'), findsNothing);
  });

  testWidgets('connected device keeps Sync now enabled', (tester) async {
    await pump(tester, localOnly: false);
    expect(tester.widget<FilledButton>(syncButton()).onPressed, isNotNull);
    expect(find.text('Pull latest data from server'), findsOneWidget);
  });

  testWidgets('kept notes are counted by the Fix sync problems entry', (
    tester,
  ) async {
    await pump(tester, localOnly: false, notes: 3);
    expect(find.text('Nothing needs fixing right now'), findsNothing);
    expect(find.text('3 kept notes to review'), findsOneWidget);
  });

  testWidgets('an unreadable notes count never claims nothing needs fixing', (
    tester,
  ) async {
    await pump(tester, localOnly: false, notesFail: true);
    expect(find.text('Nothing needs fixing right now'), findsNothing);
    expect(find.text('Check for sync problems'), findsOneWidget);
  });

  testWidgets('no notes and no changes says nothing needs fixing', (
    tester,
  ) async {
    await pump(tester, localOnly: false);
    expect(find.text('Nothing needs fixing right now'), findsOneWidget);
  });
}
