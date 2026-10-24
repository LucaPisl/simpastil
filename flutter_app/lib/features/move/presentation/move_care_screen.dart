import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/db/database.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/utils/app_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/widgets/person_avatar.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../settings/presentation/settings_overview.dart';
import '../../settings/presentation/settings_pane.dart';
import '../local_care_removal.dart';
import '../move_care_service.dart';
import '../move_plan.dart';
import '../move_providers.dart';

enum _Phase { preview, running, failed, done, removed }

enum _DuplicateChoice { keepBoth, skip }

/// Moves the care kept on this phone to the signed-in account: a backup
/// first, a preview with a choice for every likely duplicate, the copy and
/// its check, and only then the offer to remove the phone's own copy.
class MoveCareScreen extends ConsumerStatefulWidget {
  const MoveCareScreen({super.key});

  @override
  ConsumerState<MoveCareScreen> createState() => _MoveCareScreenState();
}

class _MoveCareScreenState extends ConsumerState<MoveCareScreen> {
  _Phase _phase = _Phase.preview;
  final _choices = <String, _DuplicateChoice>{};
  bool _backedUp = false;
  MoveStep? _step;
  MoveFailureCode? _failure;
  MoveOutcome? _outcome;
  Set<String> _moved = const {};
  bool _busy = false;

  Future<void> _start(MovePreview preview) async {
    if (!_backedUp) {
      final saved = await context.push<bool>('/backups?step=move');
      if (!mounted || saved != true) return;
      _backedUp = true;
    }
    await _run(preview);
  }

  Future<void> _run(MovePreview preview) async {
    final skip = {
      for (final entry in _choices.entries)
        if (entry.value == _DuplicateChoice.skip) entry.key,
    };
    setState(() {
      _phase = _Phase.running;
      _failure = null;
      _step = MoveStep.copying;
    });
    // Held for the whole move, so the service and what it reads are not
    // disposed while the move is still using them.
    final keepAlive = ref.listenManual(moveCareServiceProvider, (_, _) {});
    try {
      final service = await ref.read(moveCareServiceProvider.future);
      final outcome = await service.run(
        preview.plan,
        skipPeople: skip,
        onStep: (step) {
          if (mounted) setState(() => _step = step);
        },
      );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _moved = {
          for (final p in preview.plan.people)
            if (!skip.contains(p.id)) p.id,
        };
        _phase = _Phase.done;
      });
    } on MoveFailure catch (failure) {
      if (mounted) {
        setState(() {
          _failure = failure.code;
          _phase = _Phase.failed;
        });
      }
    } on Object catch (error, stack) {
      AppLogger.error('Move', 'The move stopped', error, stack);
      if (mounted) {
        setState(() {
          _failure = null;
          _phase = _Phase.failed;
        });
      }
    } finally {
      keepAlive.close();
    }
  }

  Future<void> _remove(MovePreview preview) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.move_removeConfirmTitle),
        content: Text(l.move_removeConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.shared_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.move_remove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await removeLocalCare(
        ref.read(databaseProvider),
        localWorkspaceId: preview.local.id,
        localOwnerId: preview.local.ownerUserId,
        profileIds: _moved,
      );
      if (mounted) setState(() => _phase = _Phase.removed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final preview = ref.watch(movePreviewProvider);
    final running = _phase == _Phase.running || _busy;
    return PopScope(
      canPop: !running,
      child: Scaffold(
        appBar: settingsDetailAppBar(
          context,
          l.move_title,
          leading: running ? const SizedBox.shrink() : null,
        ),
        body: preview.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => ContentListView(
            maxWidth: settingsContentWidth(context),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              CalmNotice(
                text: l.move_loadFailed,
                tone: StatusTone.attention,
                live: true,
              ),
              const SizedBox(height: 16),
              _PrimaryButton(
                label: l.move_tryAgain,
                onPressed: () => ref.invalidate(movePreviewProvider),
              ),
            ],
          ),
          data: (preview) => ContentListView(
            maxWidth: settingsContentWidth(context),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: switch (_phase) {
              _Phase.preview => _previewBody(context, l, preview),
              _Phase.running => _progressBody(context, l),
              _Phase.failed => [
                ..._progressBody(context, l),
                const SizedBox(height: 16),
                CalmNotice(
                  text: '${_failureText(l)}\n${l.move_failedSafe}',
                  tone: StatusTone.attention,
                  live: true,
                ),
                const SizedBox(height: 16),
                _PrimaryButton(
                  label: l.move_tryAgain,
                  onPressed: () => _run(preview),
                ),
              ],
              _Phase.done => _doneBody(context, l, preview),
              _Phase.removed => [
                CalmNotice(
                  text: l.move_removed,
                  icon: Icons.check_circle_outline,
                  tone: StatusTone.good,
                  live: true,
                ),
                const SizedBox(height: 16),
                _PrimaryButton(label: l.move_done, onPressed: _leave),
              ],
            },
          ),
        ),
      ),
    );
  }

  String _failureText(AppLocalizations l) => switch (_failure) {
    MoveFailureCode.serverNeedsUpdate => l.move_serverNeedsUpdate,
    MoveFailureCode.copyNotSent => l.move_failedCopy,
    MoveFailureCode.historyNotFound => l.move_failedHistory,
    MoveFailureCode.notVerified => l.move_failedVerify,
    MoveFailureCode.stockNeedsRecount => l.move_stockNeedsRecount,
    MoveFailureCode.stockServerNeedsUpdate => l.move_stockServerNeedsUpdate,
    null => l.move_failedUnknown,
  };

  List<Widget> _previewBody(
    BuildContext context,
    AppLocalizations l,
    MovePreview preview,
  ) {
    final theme = Theme.of(context);
    final plan = preview.plan;
    if (plan.isEmpty) {
      return [
        CalmNotice(text: l.move_nothing, tone: StatusTone.neutral),
        const SizedBox(height: 16),
        _PrimaryButton(label: l.move_done, onPressed: _leave),
      ];
    }
    final recorded = [
      for (final h in plan.history)
        if (h.finalState != null) h.occurrence.plannedLocalDate,
      for (final d in plan.prnDoses) d.occurrence.plannedLocalDate,
    ]..sort();
    final undecided = preview.duplicates.keys.any(
      (id) => !_choices.containsKey(id),
    );
    final blocked = preview.serverGap != null;
    return [
      Text(
        l.move_intro,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 20),
      SettingsGroup(
        label: l.move_whatMoves,
        children: [
          for (final person in plan.people)
            _PersonRow(
              person: person,
              medications: plan.medicationsOf(person.id).length,
              skipped: _choices[person.id] == _DuplicateChoice.skip,
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
        child: Text(
          recorded.isEmpty
              ? l.move_noDoses
              : l.move_dosesSince(
                  recorded.length,
                  DateFormat.yMMMd(
                    Localizations.localeOf(context).toString(),
                  ).format(parseRoutineDate(recorded.first)),
                ),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: settingsMutedColor(theme),
          ),
        ),
      ),
      for (final entry in preview.duplicates.entries) ...[
        _DuplicateCard(
          person: plan.people.firstWhere((p) => p.id == entry.key),
          match: entry.value,
          choice: _choices[entry.key],
          onChoice: (choice) => setState(() => _choices[entry.key] = choice),
        ),
        const SizedBox(height: 12),
      ],
      if (preview.duplicates.isNotEmpty) ...[
        Text(
          l.move_duplicateHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: settingsMutedColor(theme),
          ),
        ),
        const SizedBox(height: 20),
      ],
      for (final left in plan.leftBehind) ...[
        CalmNotice(
          text: switch (left.kind) {
            MoveLeftBehindKind.legacyHistory => l.move_legacyLeft(left.count),
            MoveLeftBehindKind.asNeededHistory => l.move_prnLeft(left.count),
          },
          icon: Icons.phone_android_outlined,
          tone: StatusTone.neutral,
        ),
        const SizedBox(height: 12),
      ],
      if (blocked)
        CalmNotice(
          text: switch (preview.serverGap) {
            MoveFailureCode.stockNeedsRecount => l.move_stockNeedsRecount,
            MoveFailureCode.stockServerNeedsUpdate =>
              l.move_stockServerNeedsUpdate,
            _ => l.move_serverNeedsUpdate,
          },
          icon: Icons.dns_outlined,
          tone: StatusTone.attention,
        )
      else ...[
        Text(l.move_backupFirst, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        _PrimaryButton(
          key: const ValueKey('move-start'),
          label: _backedUp ? l.move_tryAgain : l.move_start,
          onPressed: undecided ? null : () => _start(preview),
        ),
      ],
    ];
  }

  List<Widget> _progressBody(BuildContext context, AppLocalizations l) {
    final theme = Theme.of(context);
    final current = _step?.index ?? 0;
    final failed = _phase == _Phase.failed;
    String label(MoveStep step) => switch (step) {
      MoveStep.copying => l.move_stepCopying,
      MoveStep.history => l.move_stepHistory,
      MoveStep.recording => l.move_stepRecording,
      MoveStep.stock => l.move_stepStock,
      MoveStep.checking => l.move_stepChecking,
    };
    return [
      if (!failed) ...[
        Text(
          l.move_running,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
      ],
      Semantics(
        liveRegion: true,
        child: SettingsGroup(
          label: l.move_title,
          children: [
            for (final step in MoveStep.values)
              _StepRow(
                label: label(step),
                state: step.index < current
                    ? _StepState.done
                    : step.index == current
                    ? (failed ? _StepState.stopped : _StepState.working)
                    : _StepState.waiting,
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _doneBody(
    BuildContext context,
    AppLocalizations l,
    MovePreview preview,
  ) {
    final theme = Theme.of(context);
    final outcome = _outcome!;
    return [
      Semantics(
        liveRegion: true,
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.verified_outlined,
                size: 32,
                color: statusToneColor(theme, StatusTone.good),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l.move_doneTitle,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(l.move_doneBody, style: theme.textTheme.bodyLarge),
      const SizedBox(height: 20),
      SettingsGroup(
        label: l.move_whatMoved,
        children: [
          _SummaryRow(
            icon: Icons.people_outline,
            text: l.move_peopleCount(outcome.people),
          ),
          _SummaryRow(
            icon: Icons.medication_outlined,
            text: l.move_medicationCount(outcome.medications),
          ),
          _SummaryRow(
            icon: Icons.event_available_outlined,
            text: l.move_doseCount(outcome.doses),
          ),
        ],
      ),
      Text(l.move_keepAskBody, style: theme.textTheme.bodyLarge),
      const SizedBox(height: 16),
      _PrimaryButton(
        key: const ValueKey('move-remove-local'),
        label: l.move_remove,
        tonal: true,
        onPressed: _busy || _moved.isEmpty ? null : () => _remove(preview),
      ),
      const SizedBox(height: 8),
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: _busy ? null : _leave,
        child: Text(l.move_keepForNow),
      ),
    ];
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.tonal = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      minimumSize: const Size(0, 52),
    );
    return tonal
        ? FilledButton.tonal(
            style: style,
            onPressed: onPressed,
            child: Text(label),
          )
        : FilledButton(style: style, onPressed: onPressed, child: Text(label));
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.person,
    required this.medications,
    required this.skipped,
  });

  final Profile person;
  final int medications;
  final bool skipped;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          PersonAvatar(
            id: person.id,
            name: person.name,
            emoji: person.avatarEmoji,
            size: 40,
            muted: skipped,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  skipped
                      ? l.move_skipped
                      : l.move_medicationCount(medications),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: settingsMutedColor(theme),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A phone person beside the account person with the same name, and the
/// choice between keeping both and skipping the phone's one.
class _DuplicateCard extends StatelessWidget {
  const _DuplicateCard({
    required this.person,
    required this.match,
    required this.choice,
    required this.onChoice,
  });

  final Profile person;
  final Profile match;
  final _DuplicateChoice? choice;
  final ValueChanged<_DuplicateChoice> onChoice;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget side(Profile who, String caption) => Expanded(
      child: Row(
        children: [
          PersonAvatar(
            id: who.id,
            name: who.name,
            emoji: who.avatarEmoji,
            size: 36,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  who.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  caption,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: settingsMutedColor(theme),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: settingsBorderColor(theme)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.move_duplicateTitle(person.name),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                side(person, l.move_onPhone),
                const SizedBox(width: 12),
                side(match, l.move_onAccount),
              ],
            ),
            const SizedBox(height: 16),
            SegmentedButton<_DuplicateChoice>(
              emptySelectionAllowed: true,
              segments: [
                ButtonSegment(
                  value: _DuplicateChoice.keepBoth,
                  label: Text(l.move_keepBoth),
                ),
                ButtonSegment(
                  value: _DuplicateChoice.skip,
                  label: Text(l.move_skipPerson),
                ),
              ],
              selected: {?choice},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) onChoice(selection.single);
              },
            ),
          ],
        ),
      ),
    );
  }
}

enum _StepState { done, working, stopped, waiting }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = settingsMutedColor(theme);
    final Widget mark = switch (state) {
      _StepState.done => Icon(
        Icons.check_circle,
        color: statusToneColor(theme, StatusTone.good),
      ),
      _StepState.working => const SizedBox.square(
        dimension: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
      _StepState.stopped => Icon(
        Icons.pause_circle_outline,
        color: statusToneColor(theme, StatusTone.attention),
      ),
      _StepState.waiting => Icon(Icons.radio_button_unchecked, color: muted),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          ExcludeSemantics(
            child: SizedBox.square(dimension: 24, child: Center(child: mark)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: state == _StepState.waiting ? muted : null,
                fontWeight: state == _StepState.working
                    ? FontWeight.w600
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          ExcludeSemantics(child: Icon(icon, color: settingsMutedColor(theme))),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: theme.textTheme.bodyLarge)),
        ],
      ),
    );
  }
}
