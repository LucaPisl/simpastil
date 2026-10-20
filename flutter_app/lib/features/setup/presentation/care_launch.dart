import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../auth/auth_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/router/app_router.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/theme/focus_tokens.dart';
import '../../../shared/widgets/capsule_mark.dart';
import '../../../shared/widgets/care_state.dart';
import '../../dashboard/focus_deck.dart';
import '../../profiles/profile_provider.dart';
import '../setup_controller.dart';
import '../setup_state.dart';
import 'setup_organiser.dart';
import 'setup_screen.dart';

/// Set when the person chooses fresh care on this device over care waiting for
/// original-server review. Per launch only: the waiting care stays retained.
final retainedNoticeDismissedProvider = StateProvider<bool>((ref) => false);

/// Reading launch state does not create a draft or infer an empty workspace.
class CareLaunch extends ConsumerWidget {
  const CareLaunch({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final workspace = ref.watch(workspaceContextProvider);
    final people = ref.watch(profileListProvider);
    final draft = ref.watch(unfinishedSetupDraftProvider);
    final retained = ref.watch(retainedAccountWorkspaceProvider);
    if (workspace.hasError || people.hasError || draft.hasError) {
      return Scaffold(
        body: CareState(
          title: l.t08_unavailable,
          body: l.t08_unavailableBody,
          actionLabel: l.shared_retry,
          action: () {
            ref.invalidate(workspaceContextProvider);
            ref.invalidate(profileListProvider);
            ref.invalidate(unfinishedSetupDraftProvider);
          },
        ),
      );
    }
    if (workspace.isLoading ||
        people.isLoading ||
        draft.isLoading ||
        workspace.asData == null ||
        people.asData == null ||
        draft.asData == null) {
      return Scaffold(body: CareState(title: l.shared_loading, loading: true));
    }
    if (draft.requireValue != null) {
      return SetupScreen(
        key: ValueKey(workspace.requireValue.workspaceId),
        embedded: true,
      );
    }
    if (people.requireValue.isEmpty) {
      final waiting = retained.asData?.value?.bindingState == 'unresolved';
      if (waiting && !ref.watch(retainedNoticeDismissedProvider)) {
        return const _RetainedCareNotice();
      }
      return const _Welcome();
    }
    return const FocusTodayScreen();
  }
}

class _Welcome extends ConsumerStatefulWidget {
  const _Welcome();
  @override
  ConsumerState<_Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends ConsumerState<_Welcome> {
  bool _busy = false;
  bool _failed = false;
  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final repository = await ref.read(setupRepositoryProvider.future);
      if (!mounted) return;
      var draft = await repository.resumeOrCreateDraft();
      if (draft.step == SetupStep.complete) {
        if (mounted) context.push('/setup?purpose=person');
        return;
      }
      if (draft.step == SetupStep.start) {
        draft = await repository.advanceOrSkip(
          draft.id,
          draft.revision,
          SetupStep.person,
        );
      }
      if (mounted &&
          identical(
            ref.read(setupRepositoryProvider).asData?.value,
            repository,
          )) {
        ref.invalidate(unfinishedSetupDraftProvider);
      }
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context), colors = theme.colorScheme;
    final text = theme.textTheme;
    // A signed-in account with nobody added yet is not offered the local-only
    // choices; it is already connected and only needs its first person.
    final connected = ref.watch(authNotifierProvider) is AuthAuthenticated;
    Widget option({
      required IconData icon,
      required String label,
      String? detail,
      VoidCallback? onTap,
    }) => Pressable(
      radius: BorderRadius.circular(12),
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 10,
          ),
          leading: Icon(
            icon,
            size: 30,
            color: onTap == null ? colors.onSurfaceVariant : colors.onSurface,
          ),
          title: Text(
            label,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: detail == null ? null : Text(detail),
          trailing: onTap == null ? null : const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Simpastil',
          style: text.titleLarge?.copyWith(
            color: colors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: l.nav_settings,
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const _LaunchHeader(),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: FocusTokens.readingWidth,
                    ),
                    child: Column(
                      key: const ValueKey('setup-start'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          connected ? l.r08_connectedTitle : l.r08_startTitle,
                          style: text.displaySmall?.copyWith(
                            fontSize: 36,
                            height: 1.1,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.8,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          connected ? l.r08_connectedBody : l.r08_startBody,
                          style: text.bodyLarge?.copyWith(
                            fontSize: 18,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 28,
                          ),
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            children: [
                              SetupPhoneMark(color: colors.onPrimaryContainer),
                              const SizedBox(height: 16),
                              Text(
                                connected ? l.r08_connectedCard : l.t08_local,
                                style: text.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colors.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (!connected)
                                Text(
                                  l.r08_noAccount,
                                  textAlign: TextAlign.center,
                                  style: text.bodyLarge?.copyWith(
                                    color: colors.onPrimaryContainer,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        Pressable(
                          radius: BorderRadius.circular(12),
                          child: FilledButton(
                            key: const ValueKey('setup-begin'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 16,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _busy ? null : _start,
                            child: Text(
                              _busy
                                  ? l.t08_saving
                                  : connected
                                  ? l.r08_connectedStart
                                  : l.r08_startHere,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (!connected) ...[
                          option(
                            icon: Icons.dns_outlined,
                            label: l.r08_connect,
                            onTap: () => context.push('/login'),
                          ),
                          const SizedBox(height: 12),
                        ],
                        option(
                          icon: Icons.restore,
                          label: l.r08_restore,
                          onTap: () => context.push('/backups'),
                        ),
                        if (!connected) ...[
                          const SizedBox(height: 24),
                          Text(
                            l.r08_choiceLater,
                            textAlign: TextAlign.center,
                            style: text.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (_failed) ...[
                          const SizedBox(height: 16),
                          Text(
                            l.t08_saveError,
                            style: TextStyle(color: colors.error),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The welcome sky is always the morning: a quiet dawn with the capsule
/// rising with the sun (800 ms; reduced motion shows it already risen).
/// The launch picture: the empty organiser setup will fill, with a capsule
/// rising over it. Care kept from the previous version shows it shut and
/// full instead. The sun belongs to Today alone.
class _LaunchHeader extends StatelessWidget {
  const _LaunchHeader({this.kept = false});

  /// Care is already there, only locked: the lids are shut on it.
  final bool kept;

  static const double _height = 190;

  @override
  Widget build(BuildContext context) {
    final organiser = SetupOrganiser(filled: kept ? SetupOrganiser.count : 0);
    return ExcludeSemantics(
      child: SizedBox(
        height: _height,
        width: double.infinity,
        child: kept
            ? Center(child: organiser)
            : Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: AppMotion.duration(context, milliseconds: 800),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) => Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, 40 * (1 - t)),
                        child: child,
                      ),
                    ),
                    child: const CapsuleMark(size: 64),
                  ),
                  const SizedBox(height: 8),
                  organiser,
                  const SizedBox(height: 12),
                ],
              ),
      ),
    );
  }
}

/// Care kept from the previous version stays locked until its original server
/// is reviewed, so launch explains where it is instead of offering onboarding.
class _RetainedCareNotice extends ConsumerWidget {
  const _RetainedCareNotice();

  void _useLocal(WidgetRef ref) =>
      ref.read(retainedNoticeDismissedProvider.notifier).state = true;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context), colors = theme.colorScheme;
    final auth = ref.watch(authNotifierProvider);
    final review = auth is AuthAuthenticated && auth.requiresOriginReview;
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: l.nav_settings,
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const _LaunchHeader(kept: true),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: FocusTokens.readingWidth,
                    ),
                    child: Column(
                      key: const ValueKey('retained-care-notice'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l.rv_launchTitle,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l.rv_launchBody,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 28),
                        FilledButton(
                          key: const ValueKey('retained-care-continue'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                          ),
                          onPressed: () => context.push(
                            review ? AppPaths.originReview : AppPaths.login,
                          ),
                          child: Text(
                            review ? l.rv_launchReview : l.rv_launchSignIn,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          key: const ValueKey('retained-care-local'),
                          onPressed: () => _useLocal(ref),
                          child: Text(l.rv_launchLocal),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
