import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/core/notifications/reminder_provider.dart';
import 'package:simpastil/core/notifications/reminder_readiness.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/features/settings/presentation/reminder_privacy_settings.dart';
import 'package:simpastil/l10n/app_localizations.dart';

ProjectionReconciliationReport _coverageReport(
  ProjectionReconciliationState state, [
  int? scheduledCount,
]) => ProjectionReconciliationReport(
  userId: 'fictional-owner',
  sessionGeneration: 1,
  state: state,
  desiredCount: 12,
  scheduledCount:
      scheduledCount ??
      (state == ProjectionReconciliationState.coverageShortened ? 5 : 12),
  failedOperations: state == ProjectionReconciliationState.degraded ? 1 : 0,
  availableCount: 12,
  invalidOccurrenceCount: 0,
);

void main() {
  testWidgets(
    'privacy choice delegates once and failure retains verified full details',
    (tester) async {
      final calls = <bool>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            reminderDisplayPreferencesProvider.overrideWith(
              (_) async => ReminderPreferences(),
            ),
            reminderCoverageProvider.overrideWith((_) async => null),
            reminderReadinessProvider.overrideWith(
              (_) async => const ReminderReadiness(
                permissions: ReminderPermissions(
                  notificationsAllowed: true,
                  exactAlarmsAllowed: true,
                ),
              ),
            ),
            setReminderFullDetailsProvider.overrideWithValue((value) async {
              calls.add(value);
              throw StateError('write refused');
            }),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(child: ReminderPrivacySettings()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private reminders'));
      await tester.pumpAndSettle();
      expect(calls, [false]);
      expect(
        tester
            .widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>))
            .groupValue,
        isTrue,
      );
      await tester.scrollUntilVisible(
        find.text(
          'These details are temporarily unavailable. Your data is preserved.',
        ),
        200,
      );
      expect(
        find.text(
          'These details are temporarily unavailable. Your data is preserved.',
        ),
        findsOneWidget,
      );
      expect(find.text('I saw the test notification'), findsNothing);
    },
  );

  testWidgets('scheduled readiness is not displayed as observed delivery', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reminderDisplayPreferencesProvider.overrideWith(
            (_) async => ReminderPreferences(fullDetails: false),
          ),
          reminderCoverageProvider.overrideWith((_) async => null),
          reminderReadinessProvider.overrideWith(
            (_) async => ReminderReadiness(
              permissions: const ReminderPermissions(
                notificationsAllowed: true,
                exactAlarmsAllowed: true,
              ),
              test: ReminderTestFacts(
                testId: 'fictional',
                readinessEpoch: 1,
                grantEpoch: 1,
                requestedAt: DateTime.utc(2026, 10, 3),
                permissions: const ReminderPermissions(
                  notificationsAllowed: true,
                  exactAlarmsAllowed: true,
                ),
                scheduled: true,
                observed: false,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: ReminderPrivacySettings()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Test scheduled · delivery not confirmed'),
      findsOneWidget,
    );
    expect(find.text('You confirmed seeing this test'), findsNothing);
    expect(find.text('I saw the test notification'), findsOneWidget);
  });

  testWidgets('explains shortened reminder coverage without claiming readiness', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reminderDisplayPreferencesProvider.overrideWith(
            (_) async => ReminderPreferences(),
          ),
          reminderCoverageProvider.overrideWith(
            (_) async => _coverageReport(
              ProjectionReconciliationState.coverageShortened,
            ),
          ),
          reminderReadinessProvider.overrideWith(
            (_) async => const ReminderReadiness(
              permissions: ReminderPermissions(
                notificationsAllowed: true,
                exactAlarmsAllowed: true,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: ReminderPrivacySettings()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(
        'The nearest reminders are scheduled. Open Simpastil regularly to schedule later reminders.',
      ),
      240,
    );
    expect(
      find.text(
        'The nearest reminders are scheduled. Open Simpastil regularly to schedule later reminders.',
      ),
      findsOneWidget,
    );
    expect(find.text('All reminders are scheduled'), findsNothing);
  });

  testWidgets('shows a clear notice for degraded reminder scheduling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reminderDisplayPreferencesProvider.overrideWith(
            (_) async => ReminderPreferences(),
          ),
          reminderCoverageProvider.overrideWith(
            (_) async =>
                _coverageReport(ProjectionReconciliationState.degraded),
          ),
          reminderReadinessProvider.overrideWith(
            (_) async => const ReminderReadiness(
              permissions: ReminderPermissions(
                notificationsAllowed: true,
                exactAlarmsAllowed: true,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: ReminderPrivacySettings()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(
        'Some reminders could not be scheduled. Check notification permissions, then reopen Simpastil to try again.',
      ),
      240,
    );
    expect(
      find.text(
        'Some reminders could not be scheduled. Check notification permissions, then reopen Simpastil to try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows no-coverage notice when no reminder slots are available', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reminderDisplayPreferencesProvider.overrideWith(
            (_) async => ReminderPreferences(),
          ),
          reminderCoverageProvider.overrideWith(
            (_) async => _coverageReport(
              ProjectionReconciliationState.coverageShortened,
              0,
            ),
          ),
          reminderReadinessProvider.overrideWith(
            (_) async => const ReminderReadiness(
              permissions: ReminderPermissions(
                notificationsAllowed: true,
                exactAlarmsAllowed: true,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: ReminderPrivacySettings()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(
        'No upcoming reminders are currently scheduled for this workspace. Open Simpastil regularly to refresh coverage.',
      ),
      240,
    );
    expect(
      find.text(
        'No upcoming reminders are currently scheduled for this workspace. Open Simpastil regularly to refresh coverage.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'The nearest reminders are scheduled. Open Simpastil regularly to schedule later reminders.',
      ),
      findsNothing,
    );
  });

  testWidgets('hides stale coverage while refresh is loading or failed', (
    tester,
  ) async {
    final refresh = Completer<ProjectionReconciliationReport?>();
    var coverageReads = 0;
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [
        reminderDisplayPreferencesProvider.overrideWith(
          (_) async => ReminderPreferences(),
        ),
        reminderCoverageProvider.overrideWith((_) {
          coverageReads++;
          if (coverageReads == 1) {
            return Future.value(
              _coverageReport(ProjectionReconciliationState.coverageShortened),
            );
          }
          return refresh.future;
        }),
        reminderReadinessProvider.overrideWith(
          (_) async => const ReminderReadiness(
            permissions: ReminderPermissions(
              notificationsAllowed: true,
              exactAlarmsAllowed: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: ReminderPrivacySettings()),
          ),
        ),
      ),
    );
    const shortenedCopy =
        'The nearest reminders are scheduled. Open Simpastil regularly to schedule later reminders.';
    await tester.pumpAndSettle();
    expect(coverageReads, 1);
    expect(find.text(shortenedCopy), findsOneWidget);

    container.refresh(reminderCoverageProvider);
    await tester.pump();
    expect(coverageReads, 2);
    expect(find.text(shortenedCopy), findsNothing);

    refresh.completeError(StateError('synthetic coverage refresh failure'));
    await tester.pumpAndSettle();
    expect(find.text(shortenedCopy), findsNothing);
  });

  testWidgets('refreshes coverage after a reminder setting changes', (
    tester,
  ) async {
    var coverageReads = 0;
    final writes = <bool>[];
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reminderDisplayPreferencesProvider.overrideWith(
            (_) async => ReminderPreferences(),
          ),
          reminderCoverageProvider.overrideWith((_) async {
            coverageReads++;
            return _coverageReport(ProjectionReconciliationState.current);
          }),
          reminderReadinessProvider.overrideWith(
            (_) async => const ReminderReadiness(
              permissions: ReminderPermissions(
                notificationsAllowed: true,
                exactAlarmsAllowed: true,
              ),
            ),
          ),
          setReminderFullDetailsProvider.overrideWithValue((value) async {
            writes.add(value);
          }),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: ReminderPrivacySettings()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(coverageReads, 1);
    await tester.tap(find.text('Private reminders'));
    await tester.pumpAndSettle();
    expect(writes, [false]);
    expect(coverageReads, 2);
  });

  testWidgets('refreshes coverage when the settings route becomes current', (
    tester,
  ) async {
    var coverageReads = 0;
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reminderDisplayPreferencesProvider.overrideWith(
            (_) async => ReminderPreferences(),
          ),
          reminderCoverageProvider.overrideWith((_) async {
            coverageReads++;
            return _coverageReport(ProjectionReconciliationState.current);
          }),
          reminderReadinessProvider.overrideWith(
            (_) async => const ReminderReadiness(
              permissions: ReminderPermissions(
                notificationsAllowed: true,
                exactAlarmsAllowed: true,
              ),
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    const ReminderPrivacySettings(),
                    TextButton(
                      key: const ValueKey('open-nested-settings-route'),
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(
                            body: Center(child: Text('Nested route')),
                          ),
                        ),
                      ),
                      child: const Text('Open nested route'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(coverageReads, 1);
    await tester.ensureVisible(
      find.byKey(const ValueKey('open-nested-settings-route')),
    );
    await tester.tap(find.byKey(const ValueKey('open-nested-settings-route')));
    await tester.pumpAndSettle();
    expect(coverageReads, 1);
    Navigator.of(tester.element(find.text('Nested route'))).pop();
    await tester.pumpAndSettle();
    expect(coverageReads, 2);
  });
}
