import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/notifications/reminder_provider.dart';
import 'package:simpastil/core/notifications/reminder_readiness.dart';
import 'package:simpastil/core/projections/projection_registry.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/dashboard/reminders_off_card.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/features/settings/presentation/reminder_overview_cards.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/protected_workspace_fixture.dart';

class _Phone implements ReminderReadinessPlatform {
  bool allowed = false;
  int requests = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasNotificationPermission() async => allowed;
  @override
  Future<bool> hasExactAlarmPermission() async => allowed;
  @override
  Future<void> requestReminderAccess() async {
    requests++;
    allowed = true;
  }

  @override
  Future<void> scheduleTest(
    ReminderTestNotification test, {
    required AppLocalizations localizations,
  }) async {}
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

/// Reports every person as off and refuses to switch anyone on.
class _FailingProfiles implements ProfileRepository {
  @override
  Future<Result<bool>> getDeviceRemindersEnabled(String profileId) async =>
      const Ok(false);
  @override
  Future<Result<void>> setDeviceRemindersEnabled(
    String profileId,
    bool enabled,
  ) async => const Err(UnknownError());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  Future<
    ({ProviderContainer container, _Phone phone, ProtectedWorkspaceFixture f})
  >
  pump(
    WidgetTester tester, {
    required List<bool> remindersOn,
    Size size = const Size(390, 800),
    bool dismissed = false,
    bool allowed = false,
    bool failing = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final f = await ProtectedWorkspaceFixture.create();
    final phone = _Phone()..allowed = allowed;
    final service = ReminderReadinessService(
      database: f.db,
      access: f.access,
      context: f.context,
      preferences: ProjectionRegistry(f.preferences),
      platform: phone,
    );
    // The real repository, but without the platform reminder rebuild, which
    // talks to the notification plugin.
    final container = await f.createContainer(
      extraOverrides: [
        reminderReadinessServiceProvider.overrideWith((_) async => service),
        profileRepositoryProvider.overrideWith(
          (ref) => failing
              ? _FailingProfiles()
              : ProfileRepositoryImpl(
                  dao: f.db.profilesDao,
                  pendingOperations: ref.watch(
                    pendingOperationRepositoryProvider,
                  ),
                  userId: f.context.ownerUserId,
                  reconcileProjections: () async {},
                  access: f.access,
                  context: f.context,
                ),
        ),
      ],
    );
    if (dismissed) {
      await f.preferences.setBool(
        remindersOffNoticeDismissedPreferenceKey(f.context.ownerUserId),
        true,
      );
      container.invalidate(remindersOffDismissedProvider);
    }
    final repository = ProfileRepositoryImpl(
      dao: f.db.profilesDao,
      pendingOperations: container.read(pendingOperationRepositoryProvider),
      userId: f.context.ownerUserId,
      reconcileProjections: () async {},
      access: f.access,
      context: f.context,
    );
    for (var i = 0; i < remindersOn.length; i++) {
      final person = await repository.create('Fictional person $i', 'M');
      await repository.setDeviceRemindersEnabled(
        (person as Ok<dynamic>).value.id as String,
        remindersOn[i],
      );
    }
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      await tester.runAsync(f.db.close);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(
              child: RemindersOffCard(margin: EdgeInsets.all(8)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container: container, phone: phone, f: f);
  }

  final card = find.byKey(const ValueKey('reminders-off-card'));

  testWidgets('shows when people exist and none gets reminders here', (
    tester,
  ) async {
    await pump(tester, remindersOn: [false, false]);
    expect(card, findsOneWidget);
    expect(find.text('Reminders are off on this device'), findsOneWidget);
    expect(find.text('No one gets dose reminders here yet.'), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
  });

  testWidgets('is hidden when someone gets reminders, or nobody exists', (
    tester,
  ) async {
    await pump(tester, remindersOn: [false, true]);
    expect(card, findsNothing);
  });

  testWidgets('is hidden with no people', (tester) async {
    await pump(tester, remindersOn: const []);
    expect(card, findsNothing);
  });

  testWidgets('Turn on switches everyone on, asks for access and hides', (
    tester,
  ) async {
    final h = await pump(tester, remindersOn: [false, false]);
    await tester.tap(find.byKey(const ValueKey('reminders-off-turn-on')));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(h.phone.requests, 1);
    final repository = h.container.read(profileRepositoryProvider);
    final people = await h.container.read(profileListProvider.future);
    expect(people, hasLength(2));
    for (final p in people) {
      final on = await repository.getDeviceRemindersEnabled(p.profile.id);
      expect((on as Ok<bool>).value, isTrue);
    }
  });

  testWidgets('Turn on does not ask again when notifications are allowed', (
    tester,
  ) async {
    final h = await pump(tester, remindersOn: [false], allowed: true);
    await tester.tap(find.byKey(const ValueKey('reminders-off-turn-on')));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(h.phone.requests, 0);
  });

  testWidgets('a failed Turn on says so calmly and keeps the card', (
    tester,
  ) async {
    final h = await pump(tester, remindersOn: [false], failing: true);
    await tester.tap(find.byKey(const ValueKey('reminders-off-turn-on')));
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    expect(find.textContaining('could not be turned on'), findsOneWidget);
    expect(h.phone.requests, 0);
  });

  testWidgets('closing the card hides it for good on this device', (
    tester,
  ) async {
    final h = await pump(tester, remindersOn: [false]);
    expect(find.byTooltip('Hide on this device'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reminders-off-dismiss')));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(
      h.f.preferences.getBool(
        remindersOffNoticeDismissedPreferenceKey(h.f.context.ownerUserId),
      ),
      isTrue,
    );
    // Nobody got switched on by closing it.
    expect(
      (await h.container.read(reminderPeopleOnDeviceProvider.future))?.on,
      0,
    );
  });

  testWidgets('a card closed earlier stays closed', (tester) async {
    await pump(tester, remindersOn: [false], dismissed: true);
    expect(card, findsNothing);
  });

  testWidgets('also shows on a tablet-sized window', (tester) async {
    await pump(tester, remindersOn: [false], size: const Size(1205, 753));
    expect(card, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
