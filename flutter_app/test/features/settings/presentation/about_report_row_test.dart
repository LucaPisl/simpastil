import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/features/report/report_screen.dart';
import 'package:simpastil/features/settings/presentation/about_settings_section.dart';
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
    testWidgets('About offers Report a problem on a ${entry.key}', (
      tester,
    ) async {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            serverConfigProvider.overrideWith(_NoServer.new),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AboutSettingsSection(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('report-problem-row')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('report-problem-row')));
      // The report is still being prepared (it reads the real device), so
      // step the clock instead of waiting for it to settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(ReportProblemScreen), findsOneWidget);
      expect(find.text('Submit issue on GitHub'), findsOneWidget);
      expect(find.text('Share another way'), findsOneWidget);

      // Let the report's own time limit run out before the test ends.
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
