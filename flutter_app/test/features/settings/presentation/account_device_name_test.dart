import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/auth/auth_repository.dart';
import 'package:simpastil/features/settings/presentation/account_settings_section.dart';
import 'package:simpastil/l10n/app_localizations.dart';

import '../../../helpers/fake_auth_repository.dart';

class _Server extends ServerConfigNotifier {
  @override
  String? build() => 'https://home.example.test';
}

// Device name sits with the session options, shown once signed in.
class _SignedIn extends AuthNotifier {
  @override
  AuthState build() => const AuthAuthenticated('u1');
}

void main() {
  for (final (name, size) in const [
    ('phone', Size(400, 900)),
    ('tablet', Size(1100, 900)),
  ]) {
    group('Device name on $name', () {
      late FakeAuthRepository auth;

      Future<void> pump(WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({
          'simpastil_device_name': 'Old name',
        });
        auth = FakeAuthRepository();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              serverConfigProvider.overrideWith(_Server.new),
              authRepositoryProvider.overrideWithValue(auth),
              authNotifierProvider.overrideWith(_SignedIn.new),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: AccountSettingsSection(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tile = find.widgetWithText(ListTile, 'Device name');
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
      }

      testWidgets('saving a new name closes the dialog without errors', (
        tester,
      ) async {
        await pump(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        // The field starts with the current name.
        expect(find.widgetWithText(TextField, 'Old name'), findsOneWidget);

        await tester.enterText(find.byType(TextField), '  Kitchen tablet ');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        // The closing animation still uses the field: no pumpAndSettle shortcut
        // before it has run.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(auth.deviceNameAttempts, ['Kitchen tablet']);
        expect(find.text('Kitchen tablet'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('submitting from the keyboard saves too', (tester) async {
        await pump(tester);
        await tester.enterText(find.byType(TextField), 'Bedside');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        expect(auth.deviceNameAttempts, ['Bedside']);
      });

      testWidgets('cancelling changes nothing', (tester) async {
        await pump(tester);
        await tester.enterText(find.byType(TextField), 'Something else');
        await tester.tap(find.text('Cancel'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        expect(auth.deviceNameAttempts, isEmpty);
        expect(find.text('Old name'), findsOneWidget);
      });

      testWidgets('a failed save keeps the old name and says so', (
        tester,
      ) async {
        await pump(tester);
        auth.setDeviceNameFuture = Future.value(
          const Err<void>(ServerError(500)),
        );
        await tester.enterText(find.byType(TextField), 'Hall');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text('Old name'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
