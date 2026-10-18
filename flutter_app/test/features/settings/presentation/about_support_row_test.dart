import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/features/settings/presentation/about_settings_section.dart';
import 'package:simpastil/features/updates/presentation/update_available_card.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _NoServer extends ServerConfigNotifier {
  @override
  String? build() => null;
}

void main() {
  for (final entry in {
    'phone': const Size(390, 844),
    'tablet': const Size(1000, 1300),
  }.entries) {
    testWidgets('About opens the Ko-fi page from the support row on a '
        '${entry.key}', (tester) async {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final opened = <Uri>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            serverConfigProvider.overrideWith(_NoServer.new),
            updateLauncherProvider.overrideWithValue((uri) async {
              opened.add(uri);
            }),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AboutSettingsSection(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Support Simpastil'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('support-project-row')));
      await tester.pump();

      expect(opened, [Uri.parse('https://ko-fi.com/lucapisl')]);
    });
  }
}
