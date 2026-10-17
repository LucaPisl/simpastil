import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_error.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/router/app_router.dart';
import '../../../shared/theme/focus_tokens.dart';
import '../auth_provider.dart';

/// Shown after signing in when the account's retained care has no reviewed
/// origin. Care stays locked until the person confirms the server address is
/// the one the previous version used; declining signs out and changes nothing.
class OriginReviewScreen extends ConsumerStatefulWidget {
  const OriginReviewScreen({super.key});

  @override
  ConsumerState<OriginReviewScreen> createState() => _OriginReviewScreenState();
}

class _OriginReviewScreenState extends ConsumerState<OriginReviewScreen> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _confirm(String endpoint) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final result = await ref
        .read(authNotifierProvider.notifier)
        .confirmOriginalServer(endpoint);
    if (!mounted) return;
    switch (result) {
      case Ok():
        context.go(AppPaths.deviceName);
      case Err():
        setState(() {
          _busy = false;
          _failed = true;
        });
    }
  }

  Future<void> _reject() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref.read(authNotifierProvider.notifier).logout();
    if (mounted) context.go(AppPaths.home);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context), colors = theme.colorScheme;
    final auth = ref.watch(authNotifierProvider);
    final endpoint = auth is AuthAuthenticated && auth.requiresOriginReview
        ? auth.capability?.endpoint
        : null;
    if (endpoint == null) {
      // Nothing to review (already confirmed, signed out, or opened directly).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_busy) context.go(AppPaths.home);
      });
      return const Scaffold();
    }
    return Scaffold(
      appBar: AppBar(title: Text(l.rv_reviewTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: FocusTokens.readingWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l.rv_reviewBody,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.rv_reviewAddress,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          endpoint,
                          key: const ValueKey('origin-review-address'),
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const ValueKey('origin-review-confirm'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                    ),
                    onPressed: _busy ? null : () => _confirm(endpoint),
                    child: Text(l.rv_reviewConfirm),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const ValueKey('origin-review-reject'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                    ),
                    onPressed: _busy ? null : _reject,
                    child: Text(l.rv_reviewReject),
                  ),
                  if (_failed)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          l.rv_reviewError,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
