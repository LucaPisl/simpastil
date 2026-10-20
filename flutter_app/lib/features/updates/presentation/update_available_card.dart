import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../update_status_provider.dart';

/// Opens a release page outside the app. Overridable in tests.
final updateLauncherProvider = Provider<Future<void> Function(Uri)>(
  (ref) =>
      (uri) async => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// "Update available": a quiet card with a link to the release page and a
/// close button. Nothing is installed from here. Hides itself when there is
/// nothing to announce.
class UpdateAvailableCard extends ConsumerWidget {
  const UpdateAvailableCard({super.key, this.margin = EdgeInsets.zero});

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(updateStatusProvider).value;
    if (status == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final version = status.version;
    return Padding(
      padding: margin,
      child: Material(
        key: const ValueKey('update-available-card'),
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 8),
          child: Row(
            children: [
              Icon(
                Icons.system_update_outlined,
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.updateAvailableTitle,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                    Text(
                      version == null
                          ? l.updateAvailableBodyGeneric
                          : l.updateAvailableBody(version),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const ValueKey('update-available-open'),
                        // Line the label up with the title and body text.
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          alignment: AlignmentDirectional.centerStart,
                        ),
                        onPressed: () =>
                            ref.read(updateLauncherProvider)(status.releaseUrl),
                        child: Text(l.updateAvailableAction),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('update-available-dismiss'),
                tooltip: l.shared_close,
                icon: Icon(Icons.close, color: colors.onSecondaryContainer),
                onPressed: () =>
                    ref.read(updateStatusProvider.notifier).dismiss(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
