import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diagnostics_session.dart';
import '../../l10n/app_localizations.dart';
import 'report_screen.dart';

/// The diagnostics of this run. Replaced in tests, so no test touches the real
/// session marker.
final diagnosticsSessionProvider = Provider<DiagnosticsSession>(
  (ref) => DiagnosticsSession.shared,
);

/// The end of the previous run, when it ended badly and the person has not yet
/// dealt with it. Each incident is announced once: closing the card, or
/// opening the report from it, remembers that.
class CrashNoticeNotifier extends AsyncNotifier<CrashIncident?> {
  @override
  Future<CrashIncident?> build() =>
      ref.watch(diagnosticsSessionProvider).pendingIncident();

  Future<void> dismiss() async {
    // Hide it first: remembering it is best effort and must never keep it up.
    state = const AsyncData(null);
    try {
      await ref.read(diagnosticsSessionProvider).dismissIncident();
    } on Object {
      // The card stays hidden for this run either way.
    }
  }
}

final crashNoticeProvider =
    AsyncNotifierProvider<CrashNoticeNotifier, CrashIncident?>(
      CrashNoticeNotifier.new,
    );

/// "Simpastil closed unexpectedly last time": a quiet card on Today, shown once
/// per incident, that opens the problem report. Hides itself when the last run
/// ended normally.
class CrashNoticeCard extends ConsumerWidget {
  const CrashNoticeCard({super.key, this.margin = EdgeInsets.zero});

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incident = ref.watch(crashNoticeProvider).value;
    if (incident == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: margin,
      child: Material(
        key: const ValueKey('crash-notice-card'),
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 8),
          child: Row(
            children: [
              Icon(
                Icons.bug_report_outlined,
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.report_crashTitle,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                    Text(
                      l.report_crashBody,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const ValueKey('crash-notice-report'),
                        // Line the label up with the title and body text.
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          alignment: AlignmentDirectional.centerStart,
                        ),
                        onPressed: () {
                          // One notice per incident: opening the report counts.
                          ref.read(crashNoticeProvider.notifier).dismiss();
                          openReportProblem(context);
                        },
                        child: Text(l.report_crashAction),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('crash-notice-dismiss'),
                tooltip: l.report_crashDismiss,
                icon: Icon(Icons.close, color: colors.onSecondaryContainer),
                onPressed: () =>
                    ref.read(crashNoticeProvider.notifier).dismiss(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
