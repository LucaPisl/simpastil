import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/reminder_provider.dart';
import 'package:simpastil/core/notifications/reminder_readiness.dart';
import 'package:simpastil/core/projections/projection_registry.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
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

void main() {
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
