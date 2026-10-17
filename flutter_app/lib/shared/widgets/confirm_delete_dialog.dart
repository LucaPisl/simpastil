import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Shows a confirmation dialog for destructive delete actions.
///
/// Returns `true` if the user confirmed, `false` if they cancelled or dismissed.
///
/// [title]        — Dialog headline, e.g. "Delete Alice?"
/// [message]      — Descriptive body text explaining what will be deleted.
/// [confirmLabel] — Label for the confirm button (defaults to 'Delete').
Future<bool> showConfirmDeleteDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      final l = AppLocalizations.of(ctx);
      final effectiveLabel = confirmLabel ?? l.shared_delete;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          Semantics(
            label: l.shared_cancelDeletion,
            button: true,
            child: TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.shared_cancel),
            ),
          ),
          Semantics(
            label: l.shared_confirmAction(effectiveLabel),
            button: true,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(effectiveLabel),
            ),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
