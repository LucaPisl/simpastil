import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/reminder_provider.dart';
import 'package:simpastil/core/notifications/reminder_readiness.dart';
import 'package:simpastil/core/projections/projection_registry.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
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

void main() {
  setUpAll(tzdata.initializeTimeZones);
  Future<(_Phone, ProviderContainer)> pumpReminderStep(
    WidgetTester tester, {
    Completer<void>? hold,
  }) async {
    final f = await ProtectedWorkspaceFixture.create();
    final phone = _Phone(true)
      ..allowed = true
      ..hold = hold;
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
    final container = await f.createContainer(
      extraOverrides: [
        reminderReadinessServiceProvider.overrideWith((_) async => service),
      ],
    );
    addTearDown(() async {
      hold?.complete();
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
    return (phone, container);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
  }

  testWidgets(
    'Set up later on the reminder step moves on to the project note',
    (tester) async {
      final (phone, _) = await pumpReminderStep(tester);
      await tapKey(tester, 'check-reminders');
      await tester.pumpAndSettle();
      expect(phone.tests, hasLength(1));
      await tapKey(tester, 'reminders-continue');
      await tester.pumpAndSettle();
      // The project note comes first, then the summary with Open Today.
      expect(
        find.byKey(const ValueKey('project-note-continue')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('open-today')), findsNothing);
    },
  );

  testWidgets('Set up later still works while a reminder check is being sent', (
    tester,
  ) async {
    final (phone, _) = await pumpReminderStep(tester, hold: Completer<void>());
    await tapKey(tester, 'check-reminders');
    await tester.pump(const Duration(milliseconds: 100));
    expect(phone.tests, hasLength(1));
    await tapKey(tester, 'reminders-continue');
    await tester.pumpAndSettle();
    // The project note comes first, then the summary with Open Today.
    expect(find.byKey(const ValueKey('project-note-continue')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-today')), findsNothing);
  });

  testWidgets('a sent check shows its elapsed wait, then asks Did you see it', (
    tester,
  ) async {
    final (phone, _) = await pumpReminderStep(tester);
    await tapKey(tester, 'check-reminders');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(phone.tests, hasLength(1));
    expect(find.byKey(const ValueKey('reminder-wait')), findsOneWidget);
    expect(find.textContaining('Waiting for the reminder'), findsOneWidget);
    // Not asked yet: three seconds in, the notification may still be on its way.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Waiting for the reminder… 3 s'), findsOneWidget);
    expect(find.text('Did you see the reminder on this device?'), findsNothing);
    expect(find.byKey(const ValueKey('reminder-not-seen')), findsNothing);
    await tester.pump(const Duration(seconds: 12));
    expect(find.byKey(const ValueKey('reminder-wait')), findsNothing);
    expect(
      find.text('Did you see the reminder on this device?'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reminder-help')), findsNothing);
    await tapKey(tester, 'reminder-not-seen');
    await tester.pump();
    expect(find.byKey(const ValueKey('reminder-help')), findsOneWidget);
    // Still not confirmed, and leaving remains possible.
    expect(
      find.text('You confirmed seeing the reminder on this device.'),
      findsNothing,
    );
    await tapKey(tester, 'confirm-reminder-seen');
    await tester.pumpAndSettle();
    expect(
      find.text('You confirmed seeing the reminder on this device.'),
      findsOneWidget,
    );
  });

  testWidgets('seeing the reminder early confirms without waiting', (
    tester,
  ) async {
    await pumpReminderStep(tester);
    await tapKey(tester, 'check-reminders');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 2));
    await tapKey(tester, 'confirm-reminder-seen');
    await tester.pumpAndSettle();
    expect(
      find.text('You confirmed seeing the reminder on this device.'),
      findsOneWidget,
    );
  });

  testWidgets('the waiting and question copy is available in Romanian', (
    tester,
  ) async {
    final (_, container) = await pumpReminderStep(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: container.read(routerProvider),
          theme: AppTheme.light(),
          locale: const Locale('ro'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'check-reminders');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Se așteaptă mementoul'), findsOneWidget);
    await tester.pump(const Duration(seconds: 14));
    expect(
      find.text('Ai văzut mementoul pe acest dispozitiv?'),
      findsOneWidget,
    );
  });
}
