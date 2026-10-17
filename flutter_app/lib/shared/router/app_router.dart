import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/workspace/workspace_provider.dart';
import '../../features/setup/presentation/care_launch.dart';
import '../../features/setup/presentation/setup_screen.dart';
import '../../features/setup/setup_controller.dart';
import '../../features/setup/setup_state.dart';
import '../layouts/focus_shell.dart';
import '../motion/app_motion.dart';
import '../motion/overlay_presence.dart';
import 'back_policy.dart';
import '../../features/auth/presentation/device_name_screen.dart';
import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/origin_review_screen.dart';
import '../../features/auth/presentation/server_picker_screen.dart';
import '../../features/dashboard/history_screen.dart';
import '../../features/dashboard/dose_detail_screen.dart';
import '../../features/pills/presentation/pills_screen.dart';
import '../../features/pills/presentation/medication_detail_screen.dart';
import '../../features/schedules/presentation/routine_detail_screen.dart';
import '../../features/profiles/presentation/profiles_screen.dart';
import '../../features/schedules/presentation/schedules_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/settings/presentation/backup_settings_screen.dart';
import '../../features/settings/presentation/appearance_screen.dart';

// ── Route names ───────────────────────────────────────────────────────────────

abstract class AppRoutes {
  static const login = 'login';
  static const forgotPassword = 'forgotPassword';
  static const deviceName = 'deviceName';
  static const originReview = 'originReview';
  static const home = 'home';
  static const profiles = 'profiles';
  static const pills = 'pills';
  static const schedules = 'schedules';
  static const logs = 'logs';
  static const settings = 'settings';
}

// ── Route paths ───────────────────────────────────────────────────────────────

abstract class AppPaths {
  static const login = '/login';
  static const forgotPassword = '/forgot-password';
  static const deviceName = '/device-name';
  static const originReview = '/review-origin';
  static const home = '/home';
  static const profiles = '/profiles';
  static const pills = '/pills';
  static const schedules = '/schedules';
  static const logs = '/logs';
  static const settings = '/settings';
}

// ── Router provider ───────────────────────────────────────────────────────────

/// GoRouter is kept alive via Riverpod to survive widget rebuilds.
///
/// Care screens resolve their protected workspace without requiring a server;
/// device registration separately requires a current network capability.
/// Watches the root navigator for dialogs and sheets; see
/// [OverlayPresenceObserver].
final overlayPresenceProvider = Provider<OverlayPresenceObserver>((ref) {
  final observer = OverlayPresenceObserver();
  ref.onDispose(observer.dispose);
  return observer;
});

final routerProvider = Provider<GoRouter>((ref) {
  final overlays = ref.watch(overlayPresenceProvider);
  final router = GoRouter(
    observers: [overlays],
    initialLocation: AppPaths.home,
    debugLogDiagnostics: false, // set true during route debugging

    redirect: (context, state) async {
      // Local care is available without a server. Only the connected device
      // registration page requires the protected current network capability.
      if (state.matchedLocation == AppPaths.deviceName) {
        final network = await ref
            .read(workspaceAccessRepositoryProvider)
            .currentNetworkCapability();
        if (network == null) return AppPaths.login;
      }
      return null;
    },

    routes: [
      GoRoute(
        path: '/appearance',
        builder: (context, state) => const AppearanceScreen(),
      ),
      GoRoute(
        path: '/setup',
        builder: (context, state) => SetupScreen(
          request: SetupRequest(
            purpose: switch (state.uri.queryParameters['purpose']) {
              'person' => SetupPurpose.person,
              'medication' => SetupPurpose.medication,
              _ => SetupPurpose.onboarding,
            },
            fixedPersonId: state.uri.queryParameters['person'],
          ),
        ),
      ),
      // ── Unauthenticated routes ───────────────────────────────────────────
      GoRoute(
        name: AppRoutes.login,
        path: AppPaths.login,
        builder: (context, state) =>
            const HomeFallbackPop(child: ServerPickerScreen()),
      ),
      GoRoute(
        name: AppRoutes.forgotPassword,
        path: AppPaths.forgotPassword,
        builder: (context, state) =>
            const HomeFallbackPop(child: ForgotPasswordScreen()),
      ),
      GoRoute(
        name: AppRoutes.originReview,
        path: AppPaths.originReview,
        builder: (context, state) =>
            const HomeFallbackPop(child: OriginReviewScreen()),
      ),
      GoRoute(
        name: AppRoutes.deviceName,
        path: AppPaths.deviceName,
        builder: (context, state) =>
            const HomeFallbackPop(child: DeviceNameScreen()),
      ),
      GoRoute(
        name: AppRoutes.settings,
        path: AppPaths.settings,
        // The screen applies the Home fallback itself: its wide layout has a
        // page open beside the list that may need to keep Back for itself.
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/backups',
        builder: (context, state) => const BackupSettingsScreen(),
      ),
      GoRoute(
        path: '/people/manage',
        builder: (context, state) =>
            const HomeFallbackPop(child: ProfilesScreen()),
      ),
      // Each primary destination owns a retained navigator and scroll/form state.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            FocusShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                name: AppRoutes.home,
                path: AppPaths.home,
                pageBuilder: (context, state) => _focusPage(
                  context,
                  state,
                  state.uri.queryParameters['dose'] != null
                      ? DoseDetailScreen(
                          occurrenceId: state.uri.queryParameters['dose']!,
                        )
                      : const CareLaunch(),
                ),
              ),
              GoRoute(
                path: '/doses/:occurrenceId',
                pageBuilder: (context, state) => _focusPage(
                  context,
                  state,
                  push: true,
                  DoseDetailScreen(
                    occurrenceId: state.pathParameters['occurrenceId']!,
                  ),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                name: AppRoutes.pills,
                path: AppPaths.pills,
                pageBuilder: (context, state) =>
                    _focusPage(context, state, const PillsScreen()),
              ),
              GoRoute(
                name: AppRoutes.schedules,
                path: AppPaths.schedules,
                builder: (context, state) => const SchedulesScreen(),
              ),
              GoRoute(
                path: '/pills/:pillId',
                // The card's surface and mark fly into the page (heroes), so
                // the page itself only fades, over a longer flight.
                pageBuilder: (context, state) => _focusPage(
                  context,
                  state,
                  milliseconds: 460,
                  MedicationRoutePage(pillId: state.pathParameters['pillId']!),
                ),
              ),
              GoRoute(
                path: '/pills/:pillId/routine',
                pageBuilder: (context, state) => _focusPage(
                  context,
                  state,
                  push: true,
                  RoutineDetailScreen(pillId: state.pathParameters['pillId']!),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                name: AppRoutes.logs,
                path: AppPaths.logs,
                pageBuilder: (context, state) =>
                    _focusPage(context, state, const HistoryScreen()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                name: AppRoutes.profiles,
                path: AppPaths.profiles,
                pageBuilder: (context, state) =>
                    _focusPage(context, state, const ProfilesScreen()),
              ),
            ],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

/// Branch roots use a fade-through only. Pushed details add a 12 dp rise
/// (shared-axis style) to the entering page; quiet mode never rises.
Page<void> _focusPage(
  BuildContext context,
  GoRouterState state,
  Widget child, {
  bool push = false,
  int milliseconds = 240,
}) {
  final duration = AppMotion.duration(context, milliseconds: milliseconds);
  return CustomTransitionPage<void>(
    key: state.pageKey,
    name: state.name ?? state.path,
    arguments: <String, String>{
      ...state.pathParameters,
      ...state.uri.queryParameters,
    },
    restorationId: state.pageKey.value,
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (AppMotion.duration(context) == Duration.zero) return child;
      return AnimatedBuilder(
        animation: Listenable.merge([animation, secondaryAnimation]),
        child: child,
        builder: (context, child) {
          // The next page becomes readable only after the outgoing page fades
          // away. Reversing the same halves preserves that order on Back.
          final entering = const Interval(
            .5,
            1,
            curve: AppMotion.curve,
          ).transform(animation.value);
          final leaving =
              1 -
              const Interval(
                0,
                .5,
                curve: AppMotion.curve,
              ).transform(secondaryAnimation.value);
          final opacity = entering * leaving;
          final inactive =
              opacity == 0 || !(ModalRoute.isCurrentOf(context) ?? false);
          return IgnorePointer(
            ignoring: inactive,
            child: ExcludeSemantics(
              excluding: inactive,
              child: Opacity(
                opacity: opacity,
                child: push
                    ? Transform.translate(
                        offset: Offset(0, 12 * (1 - entering)),
                        child: child,
                      )
                    : child,
              ),
            ),
          );
        },
      );
    },
  );
}
