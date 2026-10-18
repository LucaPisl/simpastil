import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/report/diagnostic_report.dart';
import '../../core/diagnostics/report/platform_report_sources.dart';
import '../../core/diagnostics/report/report_channel.dart';
import '../../core/diagnostics/report/report_collector.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/layouts/window_size.dart';
import 'report_actions.dart';
import 'report_sources.dart';

/// Opens the problem report from anywhere inside the signed-in app: Settings,
/// the crash notice, the sync details.
Future<void> openReportProblem(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  final language = Localizations.localeOf(context).languageCode;
  final screen = WindowClass.of(context) == WindowClass.compact
      ? ReportScreen.phone
      : ReportScreen.tablet;
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ReportProblemScreen(
        collect: () => collectReport(
          appReportSources(container, screen: screen, language: language),
        ),
      ),
    ),
  );
}

/// The same screen for a moment when the app could not finish starting: it
/// reads only the phone's own facts, so it needs no database and no providers.
Future<void> openReportProblemWithoutApp(BuildContext context) {
  final language = Localizations.localeOf(context).languageCode;
  final screen = WindowClass.of(context) == WindowClass.compact
      ? ReportScreen.phone
      : ReportScreen.tablet;
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ReportProblemScreen(
        collect: () => collectReport(
          platformReportSources(screen: screen, language: language),
        ),
      ),
    ),
  );
}

enum _ShareChoice { save, email, app }

/// "Report a problem": explains what the report holds, shows it in full on
/// request, and sends it where the person chooses. Nothing leaves the phone
/// until a button is pressed, and every route uses the same file.
///
/// Free of providers on purpose, so the start-up failure screen can show it.
class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key, required this.collect, this.actions});

  /// Builds the report when the screen opens.
  final Future<DiagnosticReport> Function() collect;

  /// What the buttons do; the real ones unless a test supplies its own.
  final ReportActions? actions;

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  late final Future<DiagnosticReport> _report = widget.collect();
  late final ReportActions _actions = widget.actions ?? ReportActions();
  String? _status;
  bool _statusIsProblem = false;
  bool _busy = false;

  void _say(List<String> lines, {bool problem = false}) {
    if (!mounted) return;
    setState(() {
      _status = lines.join('\n');
      _statusIsProblem = problem;
      _busy = false;
    });
  }

  Future<void> _submitOnGitHub(DiagnosticReport report) async {
    final l = AppLocalizations.of(context);
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _GitHubStepsSheet(fileName: report.fileName),
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    final saved = await _actions.saveToDownloads(report);
    final opened = await _actions.openGitHub(report);
    _say([
      switch (saved.status) {
        ReportSaveStatus.saved => l.report_savedTo(
          saved.name ?? report.fileName,
        ),
        ReportSaveStatus.unsupported => l.report_saveUnsupported,
        ReportSaveStatus.failed => l.report_saveFailed,
      },
      if (!opened) l.report_githubOpenFailed,
    ], problem: saved.status != ReportSaveStatus.saved || !opened);
  }

  Future<void> _shareAnotherWay(DiagnosticReport report) async {
    final choice = await showModalBottomSheet<_ShareChoice>(
      context: context,
      useSafeArea: true,
      builder: (_) => const _ShareSheet(),
    );
    if (choice == null || !mounted) return;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    switch (choice) {
      case _ShareChoice.save:
        final saved = await _actions.saveToDownloads(report);
        _say([
          switch (saved.status) {
            ReportSaveStatus.saved => l.report_savedTo(
              saved.name ?? report.fileName,
            ),
            ReportSaveStatus.unsupported => l.report_saveUnsupported,
            ReportSaveStatus.failed => l.report_saveFailed,
          },
        ], problem: saved.status != ReportSaveStatus.saved);
      case _ShareChoice.email:
        final sent = await _actions.emailMaintainer(
          report,
          chooserTitle: l.report_emailAction,
        );
        switch (sent) {
          case ReportEmailStatus.opened:
            if (mounted) setState(() => _busy = false);
          case ReportEmailStatus.noEmailApp:
            _say([l.report_noEmailApp], problem: true);
          case ReportEmailStatus.failed:
            _say([l.report_emailFailed], problem: true);
        }
      case _ShareChoice.app:
        final shared = await _actions.shareWithApp(report);
        if (shared) {
          if (mounted) setState(() => _busy = false);
        } else {
          _say([l.report_shareFailed], problem: true);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.report_title)),
      body: FutureBuilder<DiagnosticReport>(
        future: _report,
        builder: (context, snapshot) {
          final report = snapshot.data;
          final ready = report != null && !_busy;
          return ContentListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(l.report_intro, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const ValueKey('report-github'),
                onPressed: ready ? () => _submitOnGitHub(report) : null,
                icon: const Icon(Icons.bug_report_outlined),
                label: Text(l.report_githubAction),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Text(
                  l.report_githubHint,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const ValueKey('report-share'),
                onPressed: ready ? () => _shareAnotherWay(report) : null,
                icon: const Icon(Icons.ios_share),
                label: Text(l.report_shareAction),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Text(
                  l.report_shareHint,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (_busy || report == null)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (_status != null) ...[
                const SizedBox(height: 16),
                _StatusCard(message: _status!, problem: _statusIsProblem),
              ],
              const SizedBox(height: 24),
              _InfoCard(
                icon: Icons.lock_outline,
                title: l.report_includesTitle,
                lines: [l.report_includesBody, l.report_neverBody],
              ),
              const SizedBox(height: 8),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  key: const ValueKey('report-preview'),
                  leading: const Icon(Icons.visibility_outlined),
                  title: Text(l.report_previewTitle),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (report == null)
                      Text(l.report_preparing)
                    else
                      SelectableText(
                        report.toText(),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                l.report_publicNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.lines,
  });

  final IconData icon;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  for (final line in lines) ...[
                    const SizedBox(height: 8),
                    Text(line, style: theme.textTheme.bodyMedium),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.message, required this.problem});

  final String message;
  final bool problem;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = problem
        ? colors.errorContainer
        : colors.secondaryContainer;
    final foreground = problem
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    return Semantics(
      liveRegion: true,
      child: Material(
        key: const ValueKey('report-status'),
        color: background,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                problem ? Icons.info_outline : Icons.check_circle_outline,
                color: foreground,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(message, style: TextStyle(color: foreground)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GitHubStepsSheet extends StatelessWidget {
  const _GitHubStepsSheet({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final steps = [
      l.report_githubStep1(fileName),
      l.report_githubStep2,
      l.report_githubStep3,
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.report_githubSheetTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(steps[i]),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('report-github-continue'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.report_githubContinue),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.shared_cancel),
          ),
        ],
      ),
    );
  }
}

class _ShareSheet extends StatelessWidget {
  const _ShareSheet();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget option(
      Key key,
      IconData icon,
      String title,
      String hint,
      _ShareChoice choice,
    ) => ListTile(
      key: key,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(hint),
      onTap: () => Navigator.of(context).pop(choice),
    );
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          option(
            const ValueKey('report-save'),
            Icons.download_outlined,
            l.report_saveAction,
            l.report_saveHint,
            _ShareChoice.save,
          ),
          option(
            const ValueKey('report-email'),
            Icons.mail_outline,
            l.report_emailAction,
            l.report_emailHint,
            _ShareChoice.email,
          ),
          option(
            const ValueKey('report-share-app'),
            Icons.ios_share,
            l.report_otherShareAction,
            l.report_otherShareHint,
            _ShareChoice.app,
          ),
        ],
      ),
    );
  }
}
