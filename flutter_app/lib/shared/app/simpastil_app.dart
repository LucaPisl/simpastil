import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/account/account_data_wipe.dart';
import '../../core/auth/auth_event_provider.dart';
import '../../core/db/database.dart';
import '../../core/storage/shared_preferences_provider.dart';
import '../../core/l10n/locale_provider.dart';
import '../../core/network/server_pin_controller.dart';
import '../../core/startup/optional_capability.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/storage/appearance_preferences.dart';
import '../../core/utils/app_logger.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/presentation/biometric_guard.dart';
import '../../features/auth/presentation/server_key_changed_screen.dart';
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
        ref.watch(appearanceNotifierProvider).value ?? AppearancePreferences();
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
  bool _keyChangedShown = false;

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
      // The sign-in step keeps one persistent note about this; a snackbar on
      // top of it would say the same thing twice.
      ref.read(signedOutNoticeProvider.notifier).state = true;
      ref.read(routerProvider).go(AppPaths.login);
    } catch (_) {
      // An unsuccessful protected transition must not present a completed logout.
      AppLogger.warning(
        'AuthFeedback',
        'Session expiry handling did not finish',
      );
    }
  }

  /// The server says the account was deleted elsewhere. Sign out, remove what
  /// this phone held for it and return to sign-in.
  Future<void> _handleAccountDeleted() async {
    try {
      final failed = ref.read(authFailureCapabilityProvider);
      ref.read(authFailureCapabilityProvider.notifier).state = null;
      final current = ref.read(authNotifierProvider);
      if (current is! AuthAuthenticated) return;
      // A late event from another connection must not wipe this one.
      if (failed != null &&
          current.capability != null &&
          failed != current.capability) {
        return;
      }
      await completeAccountDeletion(
        signOut: ref.read(authNotifierProvider.notifier).logout,
        db: ref.read(databaseProvider),
        prefs: ref.read(sharedPreferencesProvider),
        accountUserId: current.userId,
      );
      if (!mounted) return;
      ref.read(signedOutNoticeProvider.notifier).state = false;
      ref.read(routerProvider).go(AppPaths.login);
    } catch (_) {
      AppLogger.warning(
        'AuthFeedback',
        'Account removal handling did not finish',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // A server that presented a different key than the pinned one: show why
    // traffic is blocked, once per occurrence. The record may come from a
    // background sync, so this also runs on the first read at app start.
    ref.listen<AsyncValue<ServerPinState>>(serverPinControllerProvider, (
      _,
      next,
    ) {
      final changed = next.value?.hasMismatch ?? false;
      if (!changed) {
        _keyChangedShown = false;
        return;
      }
      if (_keyChangedShown) return;
      _keyChangedShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // A review the person already opened (from Sync, say) is the one to
        // use; a second copy would be left behind, out of date.
        if (mounted && !serverKeyReviewIsOpen) {
          unawaited(
            ref.read(routerProvider).push<void>(AppPaths.serverKeyChanged),
          );
        }
      });
    });
    ref.listen<AuthEvent>(authEventProvider, (_, event) {
      if (event == AuthEvent.accountDeleted) {
        unawaited(_handleAccountDeleted());
        ref.read(authEventProvider.notifier).state = AuthEvent.none;
        return;
      }
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
