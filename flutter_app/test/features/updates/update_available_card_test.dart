import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/features/updates/data/update_hint.dart';
import 'package:simpastil/features/updates/presentation/update_available_card.dart';
import 'package:simpastil/l10n/app_localizations.dart';

const _url = 'https://github.com/LucaPisl/simpastil/releases/tag/v1.2.0';

class _NoServer extends ServerConfigNotifier {
  @override
  String? build() => null;
}

Future<List<Uri>> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    UpdateHint.latestBuildKey: simpastilClientBuild + 1,
    UpdateHint.releaseUrlKey: _url,
    UpdateHint.sourceKey: 'github',
  });
  final prefs = await SharedPreferences.getInstance();
  final launched = <Uri>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        serverConfigProvider.overrideWith(_NoServer.new),
        updateLauncherProvider.overrideWithValue((uri) async {
          launched.add(uri);
        }),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: UpdateAvailableCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return launched;
}

void main() {
  for (final entry in {
    'phone': const Size(390, 800),
    'tablet': const Size(900, 1200),
  }.entries) {
    testWidgets('shows the version and opens the release on ${entry.key}', (
      tester,
    ) async {
      final launched = await _pump(tester, entry.value);
      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('Version 1.2.0 of Simpastil is out.'), findsOneWidget);
      await tester.tap(find.text('View release'));
      await tester.pump();
      expect(launched, [Uri.parse(_url)]);
    });
  }

  testWidgets('the close button dismisses the card', (tester) async {
    await _pump(tester, const Size(390, 800));
    await tester.tap(find.byKey(const ValueKey('update-available-dismiss')));
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
  });
}
