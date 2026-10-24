import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/account/account_client.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/presentation/account_self_service_sheets.dart';
import 'package:simpastil/l10n/app_localizations.dart';

import '../../helpers/protected_workspace_fixture.dart';

class _Client extends AccountClient {
  _Client() : super(Dio());
  final calls = <String>[];
  Object? failWith;

  @override
  Future<void> deleteAccount({required String password, String? code}) async {
    calls.add('delete:$password:${code ?? ''}');
    if (failWith != null) throw failWith!;
  }

  @override
  Future<EmailChangeOutcome> changeEmail({
    required String password,
    required String newEmail,
    String? code,
  }) async {
    calls.add('email:$newEmail:${code ?? ''}');
    if (failWith != null) throw failWith!;
    return EmailChangeOutcome.confirmationSent;
  }

  @override
  Future<Uint8List> exportBytes() async => Uint8List(0);
}

const _summary = AccountSummary(
  email: 'a@example.test',
  twoFactorEnabled: true,
  people: 2,
  medications: 3,
  routines: 4,
  doses: 120,
  devices: 2,
);

Future<_Client> _pump(
  WidgetTester tester,
  Widget sheet, {
  Brightness brightness = Brightness.light,
  EmailChangeMode mode = EmailChangeMode.confirm,
}) async {
  final client = _Client();
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountClientProvider.overrideWithValue(client),
        accountSummaryProvider.overrideWith((ref) async => _summary),
        unsentChangesProvider.overrideWith((ref) async => 3),
        emailChangeModeProvider.overrideWith((ref) async => mode),
      ],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness, useMaterial3: true),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(body: sheet),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return client;
}

class _SignedIn extends AuthNotifier {
  @override
  AuthState build() => const AuthAuthenticated('u1');

  @override
  Future<void> logout() async {}
}

/// The delete sheet opened over a page, under a router as in the app: Delete
/// reads the router before it calls the server.
Future<_Client> _pumpRouted(WidgetTester tester) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const DeleteAccountSheet(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/backups',
        builder: (_, _) => const Scaffold(body: Text('backups page')),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => const Scaffold(body: Text('login page')),
      ),
    ],
  );
  addTearDown(router.dispose);
  final client = _Client();
  SharedPreferences.setMockInitialValues({});
  final fixture = await ProtectedWorkspaceFixture.create(
    ownerId: 'u1',
    preferences: await SharedPreferences.getInstance(),
  );
  addTearDown(fixture.db.close);
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...fixture.overrides,
        authNotifierProvider.overrideWith(_SignedIn.new),
        currentUserIdProvider.overrideWithValue('u1'),
        accountClientProvider.overrideWithValue(client),
        accountSummaryProvider.overrideWith((ref) async => _summary),
        unsentChangesProvider.overrideWith((ref) async => 0),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return client;
}

void main() {
  for (final brightness in Brightness.values) {
    group('at text scale 1.3 in ${brightness.name}', () {
      testWidgets('change email lays out and sends the code', (tester) async {
        final client = await _pump(
          tester,
          const ChangeEmailSheet(),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        final fields = find.byType(TextField);
        expect(fields, findsNWidgets(3));
        await tester.enterText(fields.at(0), 'new@example.test');
        await tester.enterText(fields.at(1), 'secret');
        await tester.enterText(fields.at(2), '123456');
        await tester.tap(find.byKey(const ValueKey('change-email-submit')));
        await tester.pumpAndSettle();
        expect(client.calls, ['email:new@example.test:123456']);
      });

      testWidgets('change email rejects a malformed address', (tester) async {
        final client = await _pump(tester, const ChangeEmailSheet());
        await tester.enterText(find.byType(TextField).at(0), 'nope');
        await tester.tap(find.byKey(const ValueKey('change-email-submit')));
        await tester.pumpAndSettle();
        expect(client.calls, isEmpty);
        expect(find.text('Enter a valid email address.'), findsOneWidget);
      });

      testWidgets('delete shows counts, then asks for the password', (
        tester,
      ) async {
        final client = await _pump(
          tester,
          const DeleteAccountSheet(),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('2 people'), findsOneWidget);
        expect(find.text('120 doses'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        await tester.ensureVisible(
          find.byKey(const ValueKey('delete-continue')),
        );
        await tester.tap(find.byKey(const ValueKey('delete-continue')));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNWidgets(2));
        expect(
          find.text('3 changes that were not sent yet will be lost.'),
          findsOneWidget,
        );
        // Submitting with no password calls nothing.
        await tester.ensureVisible(
          find.byKey(const ValueKey('delete-account-confirm')),
        );
        await tester.tap(find.byKey(const ValueKey('delete-account-confirm')));
        await tester.pumpAndSettle();
        expect(client.calls, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('export sheet lays out', (tester) async {
        await _pump(tester, const ExportSheet(), brightness: brightness);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('export-save')), findsOneWidget);
      });
    });
  }

  testWidgets('a wrong password is shown on the field, not as a crash', (
    tester,
  ) async {
    final client = await _pump(tester, const ChangeEmailSheet());
    client.failWith = const AccountCallFailure(
      statusCode: 400,
      code: 'AUTH_INVALID_CREDENTIALS',
    );
    await tester.enterText(find.byType(TextField).at(0), 'new@example.test');
    await tester.enterText(find.byType(TextField).at(1), 'bad');
    await tester.enterText(find.byType(TextField).at(2), '000000');
    await tester.tap(find.byKey(const ValueKey('change-email-submit')));
    await tester.pumpAndSettle();
    expect(find.text('That password is not right.'), findsOneWidget);
  });

  testWidgets('immediate mode labels the button as a change', (tester) async {
    await _pump(
      tester,
      const ChangeEmailSheet(),
      mode: EmailChangeMode.immediate,
    );
    expect(find.text('Change email'), findsWidgets);
    expect(find.text('Send link'), findsNothing);
  });

  testWidgets('delete step 1 offers a backup first, then the export link, '
      'then continue', (tester) async {
    await _pump(tester, const DeleteAccountSheet());
    final backup = find.byKey(const ValueKey('delete-backup-first'));
    final export = find.byKey(const ValueKey('delete-export-first'));
    final next = find.byKey(const ValueKey('delete-continue'));
    expect(find.text('Make a backup first'), findsOneWidget);
    expect(find.text('Export my data instead'), findsOneWidget);
    expect(
      find.text(
        'A backup can be restored later, on this device or another one.',
      ),
      findsOneWidget,
    );
    final backupY = tester.getTopLeft(backup).dy;
    final exportY = tester.getTopLeft(export).dy;
    final nextY = tester.getTopLeft(next).dy;
    expect(backupY, lessThan(exportY));
    expect(exportY, lessThan(nextY));
    // The backup is the primary offer, the export a plain link.
    expect(tester.widget(backup), isA<FilledButton>());
    expect(tester.widget(export), isA<TextButton>());
  });

  testWidgets('the backup offer opens the Backups flow', (tester) async {
    final client = await _pumpRouted(tester);
    await tester.tap(find.byKey(const ValueKey('delete-backup-first')));
    await tester.pumpAndSettle();
    expect(find.text('backups page'), findsOneWidget);
    expect(find.byType(DeleteAccountSheet), findsNothing);
    expect(client.calls, isEmpty);
  });

  testWidgets('going back from Backups returns to the delete step', (
    tester,
  ) async {
    await _pumpRouted(tester);
    expect(
      find.byKey(const ValueKey('delete-back-from-backups')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('delete-backup-first')));
    await tester.pumpAndSettle();
    expect(find.text('backups page'), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(DeleteAccountSheet), findsOneWidget);
    expect(
      find.byKey(const ValueKey('delete-back-from-backups')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('delete-continue')), findsOneWidget);
  });

  testWidgets('delete recovers from an unexpected error and can be retried', (
    tester,
  ) async {
    final client = await _pumpRouted(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('delete-continue')));
    await tester.tap(find.byKey(const ValueKey('delete-continue')));
    await tester.pumpAndSettle();
    client.failWith = StateError('boom');
    await tester.enterText(find.byType(TextField).at(0), 'secret');
    await tester.enterText(find.byType(TextField).at(1), '123456');
    final confirm = find.byKey(const ValueKey('delete-account-confirm'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(client.calls, ['delete:secret:123456']);
    expect(
      find.text('The account was not deleted. Try again.'),
      findsOneWidget,
    );
    // The button is live again, and so are the fields.
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).enabled,
      true,
    );
    client.failWith = null;
    await tester.tap(confirm);
    await tester.pump();
    expect(client.calls.length, 2);
  });
}
