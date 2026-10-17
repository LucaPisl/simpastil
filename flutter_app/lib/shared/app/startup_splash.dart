import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/focus_tokens.dart';
import '../widgets/capsule_mark.dart';

/// First-frame presentation while protected startup is still pending.
/// It can render before saved preferences and application l10n are available.
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
