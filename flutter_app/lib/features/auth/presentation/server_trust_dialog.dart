import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'fingerprint_block.dart';

/// Asks whether to trust a server whose certificate this phone cannot verify
/// on its own (a self-signed one, typical of a home server). Resolves to true
/// only when the person chose to trust that exact key.
Future<bool> showServerTrustDialog(
  BuildContext context, {
  required String host,
  required String fingerprint,
}) async {
  final trusted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final l = AppLocalizations.of(dialogContext);
      final text = Theme.of(dialogContext).textTheme;
      return AlertDialog(
        title: Text(l.pin_trustTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.pin_trustBody(host), style: text.bodyMedium),
              const SizedBox(height: 16),
              FingerprintBlock(
                label: l.pin_fingerprintLabel,
                fingerprint: fingerprint,
              ),
              const SizedBox(height: 16),
              Text(l.pin_trustWarning, style: text.bodyMedium),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.shared_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.pin_trustAction),
          ),
        ],
      );
    },
  );
  return trusted == true;
}
