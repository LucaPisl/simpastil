import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_detail_provider.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/core/notifications/reminder_provider.dart';
import 'package:simpastil/core/notifications/reminder_readiness.dart';
import 'package:simpastil/core/notifications/reminder_status.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/settings/presentation/reminder_overview_cards.dart';
import 'package:simpastil/features/settings/presentation/reminder_privacy_settings.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';

ReminderPermissions _perm(bool? notifications, bool? exact) =>
    ReminderPermissions(
      notificationsAllowed: notifications,
      exactAlarmsAllowed: exact,
    );

void main() {
  group('reminderStatusOf', () {
    test('reads only existing facts, worst first', () {
      expect(reminderStatusOf(permissions: null), ReminderStatusKind.checking);
      expect(
        reminderStatusOf(permissions: _perm(null, true)),
        ReminderStatusKind.unavailable,
      );
      expect(
        reminderStatusOf(permissions: _perm(false, false)),
        ReminderStatusKind.needsPermission,
      );
      expect(
        reminderStatusOf(permissions: _perm(true, false)),
        ReminderStatusKind.mayBeLate,
      );
      expect(
        reminderStatusOf(permissions: _perm(true, true)),
        ReminderStatusKind.on,
      );
      expect(
        reminderStatusOf(
          permissions: _perm(true, true),
          coverageDegraded: true,
        ),
        ReminderStatusKind.someMissing,
      );
      // A permission problem is said before a coverage problem.
      expect(
        reminderStatusOf(
          permissions: _perm(false, true),
          coverageDegraded: true,
        ),
        ReminderStatusKind.needsPermission,
      );
    });
  });

  test('reminderTimesOf has no times without medications', () {
    expect(reminderTimesOf(const [], local: true), isEmpty);
    expect(reminderTimesOf(const [], local: false), isEmpty);
  });

  Future<void> pumpCard(
    WidgetTester tester, {
    required Widget child,
    required ReminderPermissions permissions,
    bool fullDetails = true,
    Locale locale = const Locale('en'),
    List<Override> extra = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reminderReadinessProvider.overrideWith(
            (ref) async => ReminderReadiness(permissions: permissions),
          ),
          reminderCoverageProvider.overrideWith((ref) async => null),
          reminderDisplayPreferencesProvider.overrideWith(
            (ref) async => ReminderPreferences(fullDetails: fullDetails),
          ),
          ...extra,
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('status card says reminders are on and that names are shown', (
    tester,
  ) async {
    await pumpCard(
      tester,
      child: const ReminderStatusCard(),
      permissions: _perm(true, true),
    );
    expect(find.text('Reminders on'), findsOneWidget);
    expect(find.text('Names shown'), findsOneWidget);
    expect(find.byKey(const ValueKey('reminder-status-allow')), findsNothing);
    // How a reminder looks has a card of its own, with the next reminders.
    expect(find.byKey(const ValueKey('reminder-preview')), findsNothing);
  });

  testWidgets('the status card speaks of this device, not this phone', (
    tester,
  ) async {
    await pumpCard(
      tester,
      child: const ReminderStatusCard(),
      permissions: _perm(true, true),
    );
    expect(find.text('This device'), findsOneWidget);
    expect(
      find.text('This device can show reminders at their scheduled time.'),
      findsOneWidget,
    );
    expect(find.textContaining('phone'), findsNothing);
    await pumpCard(
      tester,
      child: const ReminderStatusCard(),
      permissions: _perm(true, true),
      locale: const Locale('ro'),
    );
    expect(find.text('Acest dispozitiv'), findsOneWidget);
    expect(
      find.text('Acest dispozitiv poate afișa mementourile la ora programată.'),
      findsOneWidget,
    );
    expect(find.textContaining('telefon'), findsNothing);
  });

  test('every Reminders string says device, in both languages', () {
    for (final (locale, banned) in [('en', 'phone'), ('ro', 'telefon')]) {
      final l = lookupAppLocalizations(Locale(locale));
      final strings = {
        'title': l.r6_statusTitle,
        'checking': l.r6_statusChecking,
        'on': l.r6_statusOnBody,
        'nobody': l.r10_statusNobodyOnBody,
        'resetHint': l.reminders_resetHint,
        'resetConfirm': l.reminders_resetConfirmBody,
        'resetUnreadable': l.reminders_resetRegistryUnreadable,
      };
      strings.forEach((name, text) {
        expect(
          text.toLowerCase(),
          isNot(contains(banned)),
          reason: '$locale $name',
        );
      });
    }
  });

  testWidgets('no person switched on is not shown as reminders on', (
    tester,
  ) async {
    await pumpCard(
      tester,
      child: const ReminderStatusCard(),
      permissions: _perm(true, true),
      extra: [
        reminderPeopleOnDeviceProvider.overrideWith(
          (ref) async => (on: 0, total: 2),
        ),
      ],
    );
    expect(find.text('Reminders on'), findsNothing);
    expect(find.text('No one switched on'), findsOneWidget);
    expect(find.textContaining('widget stays empty'), findsOneWidget);
    expect(find.byKey(const ValueKey('reminder-people-hint')), findsOneWidget);
    expect(find.text('Switch a person on for this device'), findsOneWidget);
  });

  testWidgets('some people off keeps the status and adds a hint row', (
    tester,
  ) async {
    await pumpCard(
      tester,
      child: const ReminderStatusCard(),
      permissions: _perm(true, true),
      extra: [
        reminderPeopleOnDeviceProvider.overrideWith(
          (ref) async => (on: 1, total: 2),
        ),
      ],
    );
    expect(find.text('Reminders on'), findsOneWidget);
    expect(find.text('On for 1 of 2 people on this device'), findsOneWidget);
  });

  testWidgets('everyone switched on shows no hint row', (tester) async {
    await pumpCard(
      tester,
      child: const ReminderStatusCard(),
      permissions: _perm(true, true),
      extra: [
        reminderPeopleOnDeviceProvider.overrideWith(
          (ref) async => (on: 2, total: 2),
        ),
      ],
    );
    expect(find.text('Reminders on'), findsOneWidget);
    expect(find.byKey(const ValueKey('reminder-people-hint')), findsNothing);
  });

  testWidgets('private choice says so on the status card', (tester) async {
    await pumpCard(
      tester,
      child: const ReminderStatusCard(),
      permissions: _perm(true, true),
      fullDetails: false,
    );
    expect(find.text('Private'), findsOneWidget);
    expect(find.text('Names shown'), findsNothing);
  });

  testWidgets('denied notifications ask for permission', (tester) async {
    await pumpCard(
      tester,
      child: const ReminderStatusCard(),
      permissions: _perm(false, false),
    );
    expect(find.text('Needs permission'), findsOneWidget);
    expect(find.textContaining('reminders will not appear'), findsOneWidget);
    expect(find.byKey(const ValueKey('reminder-status-allow')), findsOneWidget);
  });

  testWidgets('exact alarms off says reminders may be late (RO)', (
    tester,
  ) async {
    await pumpCard(
      tester,
      child: const ReminderStatusCard(),
      permissions: _perm(true, false),
      locale: const Locale('ro'),
    );
    expect(find.text('Pot întârzia'), findsOneWidget);
  });

  testWidgets('status card wraps at 2x text without overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 800) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reminderReadinessProvider.overrideWith(
            (ref) async => ReminderReadiness(permissions: _perm(false, false)),
          ),
          reminderCoverageProvider.overrideWith((ref) async => null),
          reminderDisplayPreferencesProvider.overrideWith(
            (ref) async => ReminderPreferences(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: ReminderStatusCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Needs permission'), findsOneWidget);
  });

  testWidgets('day card without times points to the routine', (tester) async {
    await pumpCard(
      tester,
      child: const ReminderDayCard(),
      permissions: _perm(true, true),
      extra: [
        workspaceContextProvider.overrideWith(
          (ref) => Stream.value(
            const WorkspaceContext(
              workspaceId: 'w1',
              ownerUserId: 'u1',
              authorId: 'a1',
              kind: WorkspaceKind.local,
              accessEpoch: 1,
            ),
          ),
        ),
        medicationListProvider.overrideWith((ref) => Stream.value(const [])),
      ],
    );
    expect(find.text('Your reminder day'), findsOneWidget);
    expect(find.textContaining('No scheduled times yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('reminder-day-sky')), findsNothing);
    expect(find.byKey(const ValueKey('reminder-day-edit')), findsOneWidget);
  });

  /// Mounts the day card over a one-routine fixture (morning at 08:00), on a
  /// phone that reads a 12-hour clock unless [twentyFourHour] says otherwise.
  Future<void> pumpDayCard(
    WidgetTester tester, {
    bool twentyFourHour = false,
  }) async {
    tzdata.initializeTimeZones();
    final f = await CareRecordingFixture.create(routineHour: 8);
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, page) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(alwaysUse24HourFormat: twentyFourHour),
            child: page!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: ReminderDayCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('day card says its times in words, with no sky', (tester) async {
    await pumpDayCard(tester);
    expect(find.text('Reminders follow your routine times.'), findsOneWidget);
    expect(find.text('8:00 AM · Morning'), findsOneWidget);
    expect(find.byKey(const ValueKey('reminder-day-sky')), findsNothing);
  });

  testWidgets('day card follows a 24-hour phone clock', (tester) async {
    await pumpDayCard(tester, twentyFourHour: true);
    expect(find.text('08:00 · Morning'), findsOneWidget);
    expect(find.text('8:00 AM · Morning'), findsNothing);
  });
}
