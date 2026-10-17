import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_event_provider.dart';
import '../../core/l10n/locale_provider.dart';
import '../../core/startup/optional_capability.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/storage/appearance_preferences.dart';
import '../../core/utils/app_logger.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/presentation/biometric_guard.dart';
import '../../l10n/app_localizations.dart';
import '../motion/ambient_motion.dart';
import '../motion/app_motion.dart';
import '../motion/theme_reveal.dart';
import '../router/app_router.dart';
import '../theme/app_theme.dart';
import 'today_rollover.dart';

/// Application presentation, hosted by the startup and lifecycle runtime.
class SimpastilApp extends ConsumerWidget {
  const SimpastilApp({
    super.key,
    this.scaffoldMessengerKey,
    this.onLocalizationsReady,
  });

  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  /// Runs once after the saved language and the first localized frame are ready.
  final ValueChanged<AppLocalizations>? onLocalizationsReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final localeOverride = ref.watch(localeOverrideProvider);
    final appearance =
        ref.watch(appearanceNotifierProvider).valueOrNull ??
        AppearancePreferences();
    final fontMultiplier = ref.watch(fontSizeMultiplierProvider);
    final reduceMotion = ref.watch(reduceMotionProvider);
    final quiet = reduceMotion || AppMotion.quiet(context);

    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        // With quiet motion a press shows a still highlight, not a spreading
        // ripple, as the phone's own "remove animations" does.
        ThemeData still(ThemeData theme) => quiet
            ? theme.copyWith(splashFactory: NoSplash.splashFactory)
            : theme;
        final lightTheme = still(
          AppTheme.appearance(
            appearance,
            Brightness.light,
            dynamicScheme: lightDynamic,
          ),
        );
        final darkTheme = still(
          AppTheme.appearance(
            appearance,
            Brightness.dark,
            dynamicScheme: darkDynamic,
          ),
        );

        // Above the app, so a new appearance spreads over every route.
        return ThemeReveal(
          child: MaterialApp.router(
            scaffoldMessengerKey: scaffoldMessengerKey,
            title: 'Simpastil',
            debugShowCheckedModeBanner: false,
            locale: localeOverride,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: lightTheme,
            darkTheme: darkTheme,
            themeMode: ref.watch(flutterThemeModeProvider),
            themeAnimationStyle: quiet ? AnimationStyle.noAnimation : null,
            routerConfig: router,
            builder: (context, child) {
              Widget routedChild = child ?? const SizedBox.shrink();
              if (fontMultiplier != 1.0) {
                final osScale = MediaQuery.textScalerOf(context);
                routedChild = MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(
                      fontMultiplier * osScale.scale(1.0),
                    ),
                  ),
                  child: routedChild,
                );
              }
              // The app opts in to the halo breath; tests mount screens
              // without this and so never see ambient motion.
              return ReducedMotionScope(
                reduce: reduceMotion,
                child: AmbientMotion(
                  enabled: true,
                  overlayOpen: ref.read(overlayPresenceProvider).open,
                  child: TodayRollover(
                    child: _LocalizedAppEffects(
                      onLocalizationsReady: onLocalizationsReady,
                      child: BiometricGuard(
                        backButtonDispatcher: router.backButtonDispatcher,
                        child: Column(
                          children: [
                            const OptionalCapabilityBanner(),
                            Expanded(child: routedChild),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Non-visual effects that need MaterialApp's localization and messenger scope.
class _LocalizedAppEffects extends ConsumerStatefulWidget {
  const _LocalizedAppEffects({required this.child, this.onLocalizationsReady});

  final Widget child;
  final ValueChanged<AppLocalizations>? onLocalizationsReady;

  @override
  ConsumerState<_LocalizedAppEffects> createState() =>
      _LocalizedAppEffectsState();
}

class _LocalizedAppEffectsState extends ConsumerState<_LocalizedAppEffects> {
  bool _readyScheduled = false;

  Future<void> _handleSessionExpiry() async {
    try {
      // clearSession captures the failed capability before its first await.
      final accepted = await ref
          .read(authNotifierProvider.notifier)
          .clearSession();
      if (!mounted ||
          !accepted ||
          ref.read(authNotifierProvider) is! AuthUnauthenticated) {
        return;
      }
      final message = AppLocalizations.of(context).core_sessionExpired;
      final messenger = ScaffoldMessenger.of(context);
      ref.read(routerProvider).go(AppPaths.login);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 4),
          ),
        );
    } catch (_) {
      // An unsuccessful protected transition must not present a completed logout.
      AppLogger.warning(
        'AuthFeedback',
        'Session expiry handling did not finish',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthEvent>(authEventProvider, (_, event) {
      if (event != AuthEvent.sessionExpired) return;
      unawaited(_handleSessionExpiry());
      ref.read(authEventProvider.notifier).state = AuthEvent.none;
    });

    if (widget.onLocalizationsReady != null &&
        !ref.watch(localeNotifierProvider).isLoading &&
        !_readyScheduled) {
      _readyScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onLocalizationsReady?.call(AppLocalizations.of(context));
        }
      });
    }
    return widget.child;
  }
}
