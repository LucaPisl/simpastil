import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Displays an error message and a retry button, centered in available space.
/// Used as the error branch of [AsyncValueWidget].
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ExcludeSemantics(
              child: Text('⚠️', style: TextStyle(fontSize: 48)),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onRetry,
              child: Text(AppLocalizations.of(context).shared_retry),
            ),
          ],
        ),
      ),
    );
  }
}
