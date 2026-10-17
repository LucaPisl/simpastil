import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/protection/app_lock_controller.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/focus_tokens.dart';

/// The controller owns authentication. This localized boundary owns only what
/// may be painted, focused or exposed to accessibility while it is locked.
class BiometricGuard extends ConsumerStatefulWidget {
  const BiometricGuard({
    super.key,
    required this.child,
    this.backButtonDispatcher,
  });
  final Widget child;
  final BackButtonDispatcher? backButtonDispatcher;

  @override
  ConsumerState<BiometricGuard> createState() => _BiometricGuardState();
}

class _BiometricGuardState extends ConsumerState<BiometricGuard>
    with WidgetsBindingObserver {
  bool _revealed = false;
  bool _obscured = false;
  bool _suspended = false;
  bool _preserveFocusWhileInactive = false;
  ChildBackButtonDispatcher? _backDispatcher;

  Future<bool> _handleBack() async {
    final state = ref.read(appLockControllerProvider);
    return !state.canAccess || (_obscured && state.enabled);
  }

  void _attachBackDispatcher() {
    _backDispatcher =
        widget.backButtonDispatcher?.createChildBackButtonDispatcher()
          ?..addCallback(_handleBack);
  }

  void _updateBackPriority(bool visible) {
    final parent = widget.backButtonDispatcher;
    final child = _backDispatcher;
    if (parent == null || child == null) return;
    if (_revealed && !visible && parent.hasCallbacks) {
      child.takePriority();
    } else {
      parent.forget(child);
    }
  }

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _obscured = lifecycle != null && lifecycle != AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _attachBackDispatcher();
  }

  @override
  void didUpdateWidget(covariant BiometricGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backButtonDispatcher != widget.backButtonDispatcher) {
      _backDispatcher?.removeCallback(_handleBack);
      _attachBackDispatcher();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backDispatcher?.removeCallback(_handleBack);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    final controller = ref.read(appLockControllerProvider.notifier);
    if (lifecycle == AppLifecycleState.resumed) {
      _suspended = false;
      controller.resume();
      setState(() {
        _obscured = false;
        _preserveFocusWhileInactive = false;
      });
      return;
    }
    // Focus loss can be the native authentication dialog. Conceal immediately,
    // but let the controller classify an actual, once-per-cycle native pause.
    // System UI such as an autofill picker can temporarily take window focus.
    // Conceal the app below, but keep the focused input connection alive until
    // Android either returns focus or actually backgrounds the activity.
    _preserveFocusWhileInactive = lifecycle == AppLifecycleState.inactive;
    if (!_preserveFocusWhileInactive &&
        ref.read(appLockControllerProvider).enabled) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    setState(() => _obscured = true);
    _updateBackPriority(!ref.read(appLockControllerProvider).enabled);
    if (!_suspended && lifecycle != AppLifecycleState.inactive) {
      _suspended = true;
      controller.suspend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appLockControllerProvider);
    final visible = state.canAccess && (!_obscured || !state.enabled);
    if (visible) _revealed = true;
    _updateBackPriority(visible);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Never mount cold protected content. Once opened, retain it offstage so
        // a warm lock does not discard the current route, text or scroll state.
        if (_revealed)
          Offstage(
            offstage: !visible,
            child: TickerMode(
              enabled: visible,
              child: ExcludeSemantics(
                excluding: !visible,
                child: ExcludeFocus(
                  excluding:
                      !visible &&
                      !(_preserveFocusWhileInactive && state.canAccess),
                  child: IgnorePointer(ignoring: !visible, child: widget.child),
                ),
              ),
            ),
          ),
        if (!visible)
          _LockSurface(
            state: state,
            onUnlock: () => ref
                .read(appLockControllerProvider.notifier)
                .unlock(
                  AppLocalizations.of(context).shared_unlockSimpastil,
                  fallbackLabel: AppLocalizations.of(
                    context,
                  ).t14_lockUseDeviceLock,
                ),
          ),
      ],
    );
  }
}

class _LockSurface extends StatelessWidget {
  const _LockSurface({required this.state, required this.onUnlock});
  final AppLockState state;
  final Future<bool> Function() onUnlock;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final inherited = Theme.of(context);
    // Custom appearance can intentionally contain unreadable color pairs. The
    // only way back into care must remain independently legible in either mode.
    final safeTheme = ThemeData(
      useMaterial3: true,
      brightness: inherited.brightness,
      platform: inherited.platform,
      colorSchemeSeed: FocusTokens.violet,
    );
    final message = state.isAuthenticating
        ? l.t14_lockChecking
        : switch (state.failure) {
            AppLockFailure.none => l.t14_lockBody,
            AppLockFailure.cancelled => l.t14_lockCancelled,
            AppLockFailure.unavailable => l.t14_lockUnavailable,
            AppLockFailure.writeFailed => l.t14_lockWriteFailed,
            AppLockFailure.stale => l.t14_lockStale,
          };
    return Theme(
      data: safeTheme,
      child: Material(
        key: const Key('app-lock-screen'),
        color: safeTheme.colorScheme.surface,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(FocusTokens.pageInset),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 48).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Simpastil',
                          textAlign: TextAlign.center,
                          style: safeTheme.textTheme.titleLarge?.copyWith(
                            color: safeTheme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 32),
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 48,
                          color: safeTheme.colorScheme.primary,
                        ),
                        const SizedBox(height: 24),
                        Semantics(
                          header: true,
                          child: Text(
                            l.t14_lockTitle,
                            textAlign: TextAlign.center,
                            style: safeTheme.textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            message,
                            textAlign: TextAlign.center,
                            style: safeTheme.textTheme.bodyLarge,
                          ),
                        ),
                        const SizedBox(height: 32),
                        FilledButton.icon(
                          onPressed: state.isAuthenticating ? null : onUnlock,
                          icon: const Icon(Icons.lock_open_rounded),
                          label: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(l.shared_unlock),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
