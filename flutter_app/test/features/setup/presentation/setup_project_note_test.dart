import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/device/battery_optimization.dart';
import 'package:simpastil/core/notifications/reminder_provider.dart';
import 'package:simpastil/core/notifications/reminder_readiness.dart';
import 'package:simpastil/core/projections/projection_registry.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/features/setup/presentation/project_note.dart';
import 'package:simpastil/features/setup/project_links.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/features/updates/presentation/update_available_card.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../../../helpers/protected_workspace_fixture.dart';

class _Phone implements ReminderReadinessPlatform {
  _Phone(this.accept);
  final bool accept;
  bool allowed = false;
  int requests = 0;
  Completer<void>? hold;
  final tests = <ReminderTestNotification>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasNotificationPermission() async => allowed;
  @override
  Future<bool> hasExactAlarmPermission() async => allowed;
  @override
  Future<void> requestReminderAccess() async {
    requests++;
    allowed = accept;
  }

  @override
  Future<void> scheduleTest(
    ReminderTestNotification test, {
    required AppLocalizations localizations,
  }) async {
    tests.add(test);
    await hold?.future;
  }

  @override
  Future<List<PlatformReminderRequest>> pendingRequests() async => [];
  @override
  Future<void> schedule(
    ReminderProjection reminder, {
    required AppLocalizations localizations,
  }) async {}
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> cancelAll() async {}
}

class _Battery extends BatteryOptimization {
  _Battery({this.restricted = false});
  final bool restricted;

  /// Reads fail from the moment a test sets this.
  bool unreadable = false;
  @override
  Future<bool> isRestricted() async {
    if (unreadable) throw StateError('unreadable');
    return restricted;
  }

  @override
  Future<bool> requestUnrestricted() async => true;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  Future<(_Phone, ProviderContainer, List<Uri>)> pumpReminderStep(
    WidgetTester tester, {
    bool allowed = true,
    BatteryOptimization? battery,
  }) async {
    final f = await ProtectedWorkspaceFixture.create();
    final phone = _Phone(true)..allowed = allowed;
    final service = ReminderReadinessService(
      database: f.db,
      access: f.access,
      context: f.context,
      preferences: ProjectionRegistry(f.preferences),
      platform: phone,
    );
    final repo = SetupRepository(
      database: f.db,
      access: f.access,
      context: f.context,
    );
    var draft = await repo.resumeOrCreateDraft();
    draft = (await repo.savePerson(
      draft.id,
      draft.revision,
      name: 'Fictional Mara',
      avatar: 'M',
    )).draft;
    final saved = await repo.saveMedication(
      draft.id,
      draft.revision,
      const MedicationReview(name: 'Fictional medicine'),
    );
    await repo.advanceOrSkip(
      saved.draft.id,
      saved.draft.revision,
      SetupStep.reminders,
    );
    final opened = <Uri>[];
    final container = await f.createContainer(
      extraOverrides: [
        reminderReadinessServiceProvider.overrideWith((_) async => service),
        batteryOptimizationProvider.overrideWithValue(battery ?? _Battery()),
        updateLauncherProvider.overrideWithValue(
          (uri) async => opened.add(uri),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: container.read(routerProvider),
          theme: AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (phone, container, opened);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('a short project note comes before the summary', (tester) async {
    final (_, _, opened) = await pumpReminderStep(tester);
    await tapKey(tester, 'reminders-continue');
    expect(find.text('A small project'), findsOneWidget);
    expect(find.textContaining('Report a problem in Settings'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-today')), findsNothing);
    expect(find.byKey(const ValueKey('setup-summary')), findsNothing);
    // Only Ko-fi is set up; GitHub Sponsors is not ready yet.
    expect(find.byKey(const ValueKey('project-sponsors')), findsNothing);
    expect(find.byKey(const ValueKey('project-kofi')), findsOneWidget);
    expect(find.text('Found a problem?'), findsOneWidget);
    expect(find.text('Want to help build it?'), findsOneWidget);
    expect(find.text('Support the project'), findsOneWidget);

    await tapKey(tester, 'project-report');
    await tapKey(tester, 'project-code');
    await tapKey(tester, 'project-kofi');
    expect(opened, [issuesUrl, repositoryUrl, Uri.parse(kofiUrl)]);
    expect(kofiUrl, 'https://ko-fi.com/lucapisl');
    expect(
      issuesUrl.toString(),
      'https://github.com/LucaPisl/simpastil/issues',
    );
    expect(repositoryUrl.toString(), 'https://github.com/LucaPisl/simpastil');

    await tapKey(tester, 'project-note-continue');
    expect(find.text('Ready for your day.'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-today')), findsOneWidget);
    expect(find.text('A small project'), findsNothing);
  });

  testWidgets('the note and the summary also fit a tablet window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpReminderStep(tester);
    await tapKey(tester, 'reminders-continue');
    expect(find.byKey(const ValueKey('project-report')), findsOneWidget);
    await tapKey(tester, 'project-note-continue');
    expect(find.byKey(const ValueKey('setup-summary')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back goes summary, note, reminders', (tester) async {
    await pumpReminderStep(tester);
    await tapKey(tester, 'reminders-continue');
    await tapKey(tester, 'project-note-continue');
    expect(find.byKey(const ValueKey('open-today')), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-note-continue')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-today')), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reminders-continue')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-note-continue')), findsNothing);

    // Forward again: the note is shown before the summary every time.
    await tapKey(tester, 'reminders-continue');
    expect(find.byKey(const ValueKey('project-note-continue')), findsOneWidget);
  });

  testWidgets('the summary lists what is on and hides nothing it can read', (
    tester,
  ) async {
    await pumpReminderStep(tester);
    await tapKey(tester, 'reminders-continue');
    await tapKey(tester, 'project-note-continue');
    expect(find.byKey(const ValueKey('setup-summary')), findsOneWidget);
    expect(find.text('Notifications are allowed'), findsOneWidget);
    expect(find.text('No battery limits for Simpastil'), findsOneWidget);
    expect(
      find.text('Medication names show on the lock screen'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('summary-person-reminders')),
      findsOneWidget,
    );
    // A local-only device says backups are not automatic and where to make one.
    expect(
      find.text('Backups are not automatic. Make one in Settings → Backups.'),
      findsOneWidget,
    );
    // Nothing is off, so no row points anywhere to change it.
    expect(find.textContaining('Change it in Settings'), findsNothing);
  });

  testWidgets('a row that is off says where to change it', (tester) async {
    await pumpReminderStep(
      tester,
      allowed: false,
      battery: _Battery(restricted: true),
    );
    await tapKey(tester, 'reminders-continue');
    await tapKey(tester, 'project-note-continue');
    expect(find.text('Notifications are not allowed yet'), findsOneWidget);
    expect(find.text('Battery saver may delay reminders'), findsOneWidget);
    expect(find.text('Change it in Settings → Reminders.'), findsNWidgets(2));
  });

  testWidgets('a row that cannot be read is left out', (tester) async {
    final battery = _Battery();
    await pumpReminderStep(tester, battery: battery);
    await tapKey(tester, 'reminders-continue');
    // The reminders step read it fine; the summary's own read fails.
    battery.unreadable = true;
    await tapKey(tester, 'project-note-continue');
    expect(find.byKey(const ValueKey('summary-battery')), findsNothing);
    expect(find.byKey(const ValueKey('summary-notifications')), findsOneWidget);
  });

  testWidgets('with no donation pages set, it promises code help only', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: SetupProjectNote(donationLinks: [])),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('project-sponsors')), findsNothing);
    expect(find.byKey(const ValueKey('project-kofi')), findsNothing);
    expect(find.text('Want to help build it?'), findsOneWidget);
    expect(find.text('Support the project'), findsNothing);
  });

  double opacityOf(WidgetTester tester, String text) {
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(of: find.text(text), matching: find.byType(FadeTransition))
          .first,
    );
    return fade.opacity.value;
  }

  Widget note({bool reduceMotion = false}) => ProviderScope(
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: const Scaffold(
        body: SingleChildScrollView(child: SetupProjectNote()),
      ),
    ),
  );

  testWidgets('the cards rise into place once, then stay still', (
    tester,
  ) async {
    await tester.pumpWidget(note());
    expect(opacityOf(tester, 'Found a problem?'), 0);
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'Found a problem?'), 1);
    expect(opacityOf(tester, 'Support the project'), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('with reduced motion everything is there at once', (
    tester,
  ) async {
    await tester.pumpWidget(note(reduceMotion: true));
    await tester.pump();
    expect(opacityOf(tester, 'Found a problem?'), 1);
    expect(opacityOf(tester, 'Support the project'), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
