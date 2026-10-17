import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

class SettingsIcon extends StatelessWidget {
  const SettingsIcon({super.key, required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }
}

// ── SettingsSectionHeader ────────────────────────────────────────────────────────────

/// Uppercase spaced section header label.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      header: true,
      label: label,
      child: ExcludeSemantics(
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
            color: cs.primary,
          ),
        ),
      ),
    );
  }
}

class SettingsErrorTile extends StatelessWidget {
  const SettingsErrorTile({
    super.key,
    required this.label,
    required this.onRetry,
  });

  final String label;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: TextButton(
        onPressed: onRetry,
        child: Text(AppLocalizations.of(context).shared_retry),
      ),
    );
  }
}
