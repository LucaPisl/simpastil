import 'package:flutter/material.dart';

import '../../features/report/report_screen.dart';
import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/focus_tokens.dart';
import '../widgets/capsule_mark.dart';

/// First-frame presentation while protected startup is still pending.
/// It can render before saved preferences are available, so it follows the
/// device language rather than the language chosen in Settings.
class StartupSplash extends StatelessWidget {
  const StartupSplash({super.key, this.failed = false, this.onRetry});

  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final isRomanian =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ro';
    final loadingLabel = isRomanian
        ? 'Se încarcă Simpastil'
        : 'Loading Simpastil';
    final failureMessage = isRomanian
        ? 'Simpastil nu s-a putut deschide.'
        : 'Simpastil couldn’t open.';
    return MaterialApp(
      title: 'Simpastil',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      // The problem report and its button use the app's own strings; they load
      // at once. The language is pinned to what this screen already shows, so
      // the report never reads differently from the screen it opens from.
      locale: Locale(isRomanian ? 'ro' : 'en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          final reducedMotion = MediaQuery.disableAnimationsOf(context);
          final content = Padding(
            padding: const EdgeInsets.all(FocusTokens.pageInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CapsuleMark(size: 64),
                const SizedBox(height: 20),
                Text(
                  'Simpastil',
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                if (failed) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      failureMessage,
                      style: Theme.of(context).textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: onRetry,
                    child: Text(isRomanian ? 'Încearcă din nou' : 'Try again'),
                  ),
                  // A failed start is exactly when a report is most useful, and
                  // it needs neither the database nor the account.
                  TextButton(
                    key: const ValueKey('startup-report'),
                    onPressed: () => openReportProblemWithoutApp(context),
                    child: Text(
                      AppLocalizations.of(context).report_startupAction,
                    ),
                  ),
                ] else
                  TickerMode(
                    enabled: !reducedMotion,
                    child: SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        semanticsLabel: loadingLabel,
                      ),
                    ),
                  ),
              ],
            ),
          );
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: failed ? SingleChildScrollView(child: content) : content,
              ),
            ),
          );
        },
      ),
    );
  }
}
