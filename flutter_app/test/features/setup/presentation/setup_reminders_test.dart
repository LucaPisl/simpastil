import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/device/battery_optimization.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/notifications/reminder_provider.dart';
import 'package:simpastil/core/notifications/reminder_readiness.dart';
import 'package:simpastil/core/projections/projection_registry.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/features/settings/presentation/reminder_privacy_settings.dart';
import 'package:simpastil/features/setup/presentation/setup_reminders.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import '../../../helpers/protected_workspace_fixture.dart';

class _Phone implements ReminderReadinessPlatform {
  _Phone(this.accept);
  final bool accept;
  bool allowed = false;
  int requests = 0;
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
  _Battery({this.restricted = true, this.grants = true});
  bool restricted;
  final bool grants;
  int requests = 0;
  @override
  Future<bool> isRestricted() async => restricted;
  @override
  Future<bool> requestUnrestricted() async {
    requests++;
    if (grants) restricted = false;
    return !restricted;
  }
}

Profile _person(String id, String name) => Profile(
  id: id,
  userId: 'u1',
  name: name,
  avatarEmoji: 'A',
  isActive: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  serverId: null,
  revision: 1,
  syncStatus: 'pending',
  lastSyncAt: null,
  isDeleted: false,
);

class _Profiles implements ProfileRepository {
  _Profiles({this.enabled = true, this.failSave = false});
  bool enabled;
  final bool failSave;
  int saves = 0;
  @override
  Future<Result<bool>> getDeviceRemindersEnabled(String profileId) async =>
      Ok(enabled);
  @override
  Future<Result<void>> setDeviceRemindersEnabled(
    String profileId,
    bool value,
  ) async {
    saves++;
    if (failSave) return const Err(UnknownError());
    enabled = value;
    return const Ok(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The reminders step as setup shows it, with notifications [allowed] on the
/// fake phone and the given [battery] and [profiles].
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  bool allowed = true,
  String? personId,
  _Battery? battery,
  _Profiles? profiles,
  VoidCallback? onContinue,
}) async {
  final f = await ProtectedWorkspaceFixture.create(ownerId: 'u1');
  final phone = _Phone(true)..allowed = allowed;
  final service = ReminderReadinessService(
    database: f.db,
    access: f.access,
    context: f.context,
    preferences: ProjectionRegistry(f.preferences),
    platform: phone,
  );
  final container = await f.createContainer(
    extraOverrides: [
      reminderReadinessServiceProvider.overrideWith((_) async => service),
      batteryOptimizationProvider.overrideWithValue(battery ?? _Battery()),
      if (profiles != null) ...[
        profileRepositoryProvider.overrideWithValue(profiles),
        profileMembershipProvider.overrideWith(
          (_) => Stream.value([_person('p1', 'Fictional Alex')]),
        ),
      ],
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
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SetupReminders(
              personId: personId,
              onContinue: onContinue ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

bool _switchValue(WidgetTester tester, String key) =>
    tester.widget<SwitchListTile>(find.byKey(ValueKey(key))).value;

void main() {
  group('person reminders switch', () {
    testWidgets('shows the person and the stored choice, and saves a change', (
      tester,
    ) async {
      final profiles = _Profiles(enabled: true);
      await _pump(tester, personId: 'p1', profiles: profiles);
      expect(find.text('Remind me about Fictional Alex'), findsOneWidget);
      expect(_switchValue(tester, 'person-reminders-switch'), isTrue);

      await _tap(tester, 'person-reminders-switch');
      expect(profiles.saves, 1);
      expect(profiles.enabled, isFalse);
      expect(_switchValue(tester, 'person-reminders-switch'), isFalse);
      expect(find.byKey(const ValueKey('choice-failed')), findsNothing);

      await _tap(tester, 'person-reminders-switch');
      expect(profiles.enabled, isTrue);
      expect(_switchValue(tester, 'person-reminders-switch'), isTrue);
    });

    testWidgets('reads a person who starts off as off', (tester) async {
      await _pump(tester, personId: 'p1', profiles: _Profiles(enabled: false));
      expect(_switchValue(tester, 'person-reminders-switch'), isFalse);
    });

    testWidgets('a save that fails says so calmly and keeps the old choice', (
      tester,
    ) async {
      final profiles = _Profiles(enabled: true, failSave: true);
      await _pump(tester, personId: 'p1', profiles: profiles);
      await _tap(tester, 'person-reminders-switch');
      expect(find.byKey(const ValueKey('choice-failed')), findsOneWidget);
      expect(_switchValue(tester, 'person-reminders-switch'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is absent without a person', (tester) async {
      await _pump(tester, profiles: _Profiles());
      expect(
        find.byKey(const ValueKey('person-reminders-switch')),
        findsNothing,
      );
    });
  });

  group('lock-screen details switch', () {
    testWidgets('writes the choice and the preview follows it', (tester) async {
      final container = await _pump(tester);
      expect(_switchValue(tester, 'reminder-details-switch'), isTrue);
      expect(find.textContaining('your medicine'), findsWidgets);
      expect(
        (await container.read(
          reminderDisplayPreferencesProvider.future,
        )).fullDetails,
        isTrue,
      );

      await _tap(tester, 'reminder-details-switch');
      expect(_switchValue(tester, 'reminder-details-switch'), isFalse);
      expect(
        (await container.read(
          reminderDisplayPreferencesProvider.future,
        )).fullDetails,
        isFalse,
      );
      expect(find.text('A gentle reminder'), findsOneWidget);
      expect(find.textContaining('your medicine'), findsNothing);

      await _tap(tester, 'reminder-details-switch');
      expect(_switchValue(tester, 'reminder-details-switch'), isTrue);
      expect(find.textContaining('your medicine'), findsWidgets);
    });

    testWidgets('is offered before notifications are allowed', (tester) async {
      await _pump(tester, allowed: false);
      expect(
        find.byKey(const ValueKey('reminder-details-switch')),
        findsOneWidget,
      );
    });

    testWidgets('the main action comes before the optional choices', (
      tester,
    ) async {
      await _pump(
        tester,
        personId: 'p1',
        allowed: false,
        profiles: _Profiles(enabled: true),
      );
      double top(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      expect(top('allow-reminders'), lessThan(top('person-reminders-switch')));
      expect(
        top('person-reminders-switch'),
        lessThan(top('reminder-details-switch')),
      );
      expect(
        top('reminder-details-switch'),
        lessThan(top('reminders-continue')),
      );
      expect(find.text('Your choices'), findsOneWidget);
    });
  });

  group('battery guidance', () {
    testWidgets(
      'a restricted phone with notifications on gets a skippable card',
      (tester) async {
        final battery = _Battery(restricted: true, grants: false);
        await _pump(tester, battery: battery);
        expect(find.byKey(const ValueKey('battery-card')), findsOneWidget);
        expect(find.text('Keep reminders on time'), findsOneWidget);
        expect(
          find.text('Let Simpastil run in the background'),
          findsOneWidget,
        );
        expect(find.textContaining('Background usage limits'), findsOneWidget);
        expect(find.text('Battery: no limits'), findsNothing);

        await _tap(tester, 'battery-not-now');
        expect(find.byKey(const ValueKey('battery-card')), findsNothing);
        expect(find.text('Battery: no limits'), findsNothing);
        expect(battery.requests, 0);
      },
    );

    testWidgets('allowing asks the system, then the card gives way to a chip', (
      tester,
    ) async {
      final battery = _Battery(restricted: true);
      await _pump(tester, battery: battery);
      await _tap(tester, 'battery-allow');
      expect(battery.requests, 1);
      expect(find.byKey(const ValueKey('battery-card')), findsNothing);
      expect(find.text('Battery: no limits'), findsOneWidget);
    });

    testWidgets('a declined request keeps the card', (tester) async {
      final battery = _Battery(restricted: true, grants: false);
      await _pump(tester, battery: battery);
      await _tap(tester, 'battery-allow');
      expect(battery.requests, 1);
      expect(find.byKey(const ValueKey('battery-card')), findsOneWidget);
    });

    testWidgets('an unrestricted phone shows only the chip', (tester) async {
      await _pump(tester, battery: _Battery(restricted: false));
      expect(find.byKey(const ValueKey('battery-card')), findsNothing);
      expect(find.text('Battery: no limits'), findsOneWidget);
    });

    testWidgets('nothing about batteries before notifications are allowed', (
      tester,
    ) async {
      await _pump(tester, allowed: false, battery: _Battery(restricted: true));
      expect(find.byKey(const ValueKey('battery-card')), findsNothing);
      expect(find.text('Battery: no limits'), findsNothing);
    });

    testWidgets('coming back from system settings reads the status again', (
      tester,
    ) async {
      final battery = _Battery(restricted: true, grants: false);
      await _pump(tester, battery: battery);
      expect(find.byKey(const ValueKey('battery-card')), findsOneWidget);
      battery.restricted = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('battery-card')), findsNothing);
      expect(find.text('Battery: no limits'), findsOneWidget);
    });
  });

  for (final allowed in [false, true]) {
    testWidgets(
      allowed
          ? 'setup distinguishes scheduling from explicit observed confirmation'
          : 'denied reminders never block leaving saved setup',
      (tester) async {
        final f = await ProtectedWorkspaceFixture.create();
        final phone = _Phone(allowed);
        final service = ReminderReadinessService(
          database: f.db,
          access: f.access,
          context: f.context,
          preferences: ProjectionRegistry(f.preferences),
          platform: phone,
        );
        final container = await f.createContainer(
          extraOverrides: [
            reminderReadinessServiceProvider.overrideWith((_) async => service),
          ],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.db.close();
          container.dispose();
          await tester.pumpAndSettle();
        });
        var continued = 0;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: SetupReminders(onContinue: () => continued++),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(phone.requests, 0);
        await _tap(tester, 'allow-reminders');
        expect(phone.requests, 1);
        if (allowed) {
          expect(find.text('Notifications allowed'), findsOneWidget);
          expect(find.text('Test reminder not confirmed'), findsOneWidget);
          expect(find.text('Test reminder confirmed'), findsNothing);
          await _tap(tester, 'check-reminders');
          expect(phone.tests, hasLength(1));
          expect(find.text('Test reminder not confirmed'), findsOneWidget);
          expect(find.text('Test reminder confirmed'), findsNothing);
          expect(
            (await _read(tester, service.inspect())).deliveryConfirmed,
            isFalse,
          );
          await _tap(tester, 'confirm-reminder-seen');
          expect(
            (await _read(tester, service.inspect())).deliveryConfirmed,
            isTrue,
          );
          expect(find.text('Test reminder confirmed'), findsOneWidget);
        } else {
          expect(find.byKey(const ValueKey('check-reminders')), findsNothing);
          expect(
            find.byKey(const ValueKey('confirm-reminder-seen')),
            findsNothing,
          );
          expect(phone.tests, isEmpty);
        }
        await _tap(tester, 'reminders-continue');
        expect(continued, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a pending check is not offered once notifications are off', (
    tester,
  ) async {
    final f = await ProtectedWorkspaceFixture.create();
    final phone = _Phone(true)..allowed = true;
    final service = ReminderReadinessService(
      database: f.db,
      access: f.access,
      context: f.context,
      preferences: ProjectionRegistry(f.preferences),
      platform: phone,
    );
    final container = await f.createContainer(
      extraOverrides: [
        reminderReadinessServiceProvider.overrideWith((_) async => service),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    await _read(tester, service.requestTest(localizations: en));
    expect(phone.tests, hasLength(1));
    // The person then turns notifications off in Android settings.
    phone.allowed = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: SetupReminders(onContinue: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-reminder-seen')), findsNothing);
    expect(find.byKey(const ValueKey('allow-reminders')), findsOneWidget);
    expect(find.text('Gentle reminders, if you want them'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<T> _read<T>(WidgetTester tester, Future<T> operation) async {
  var done = false;
  T? value;
  Object? error;
  operation.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!done) throw StateError('Protected query did not settle');
  if (error != null) throw error!;
  return value as T;
}
