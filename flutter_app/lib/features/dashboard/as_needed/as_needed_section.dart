import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/medication/care_provider.dart';
import '../../../core/storage/as_needed_hint_preference.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/widgets/care_state.dart';
import '../../pills/presentation/medication_identity.dart';
import '../../settings/presentation/settings_overview.dart';
import '../../settings/presentation/settings_screen.dart';
import 'as_needed_controller.dart';
import 'as_needed_details_sheet.dart';
import 'as_needed_dose_editor.dart';
import 'as_needed_option.dart';
import 'as_needed_ring_card.dart';
import 'as_needed_summary.dart';
import '../today_side/today_card.dart';

/// The As needed section of Today: a header with a compact log of today's
/// doses, then one ring card per as-needed medication. Hold a card to record a
/// dose; tap it for the details. Shared by the local and connected paths.
class AsNeededSection extends ConsumerStatefulWidget {
  const AsNeededSection({
    super.key,
    required this.request,
    this.card = false,
    this.maxColumns = 2,
  });

  /// The viewed day and person.
  final CareDayRequest request;

  /// Draws the section as a card of its own (the tablet's side column)
  /// instead of a block with space above it in the page.
  final bool card;

  /// The most cards a row holds. A row takes fewer when the width does not
  /// leave each card room (see `_minCardWidth`).
  final int maxColumns;

  @override
  ConsumerState<AsNeededSection> createState() => _AsNeededSectionState();
}

/// The narrowest a ring card is given before a row takes one card fewer.
const double _minCardWidth = 118;

class _AsNeededSectionState extends ConsumerState<AsNeededSection> {
  late final AsNeededController _controller = AsNeededController(
    ref: ref,
    localDate: () => widget.request.localDate,
    canFeel: () =>
        mounted &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true),
    onUndoStockUnchanged: () {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).t08_undoStockUnchanged),
          duration: const Duration(seconds: 8),
        ),
      );
    },
  );
  bool _logOpen = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _hold(AsNeededOption option) async {
    final ok = await _controller.record(
      option,
      amount: option.usualAmount,
      at: _controller.holdTime(),
    );
    if (ok && mounted) {
      ref.read(asNeededHintDismissedProvider.notifier).dismiss();
    }
  }

  void _openReview() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => const SettingsScreen(section: SettingsSection.data),
    ),
  );

  void _openDetails(AsNeededOption option) {
    showAsNeededDetailsSheet(
      context,
      option: option,
      onRecordNow: () async {
        final ok = await _controller.record(
          option,
          amount: option.usualAmount,
          at: _controller.holdTime(),
          fresh: true,
        );
        if (ok && mounted) {
          ref.read(asNeededHintDismissedProvider.notifier).dismiss();
        }
      },
      onOpenEditor: () => openAsNeededDoseEditor(
        context,
        option: option,
        controller: _controller,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final workspace = ref.watch(workspaceContextProvider).asData?.value;
    final options = ref.watch(asNeededOptionsProvider(widget.request));
    if (options.hasError) {
      // The local path already reports a failed day above.
      return workspace != null && !workspace.isLocal
          ? CareState(title: l.t08_unavailable, body: l.t08_unavailableBody)
          : const SizedBox.shrink();
    }
    final list = options.asData?.value;
    if (list == null || list.isEmpty) return const SizedBox.shrink();
    final summaries = ref.watch(asNeededSummariesProvider).value ?? const {};
    AsNeededSummary summaryOf(AsNeededOption o) =>
        summaries[o.pillId] ?? AsNeededSummary.empty(o.pillId);
    final hintDismissed = ref.watch(asNeededHintDismissedProvider);
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => _frame(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              title: l.t08_asNeeded,
              summaries: [for (final o in list) (o, summaryOf(o))],
              open: _logOpen,
              onToggle: () => setState(() => _logOpen = !_logOpen),
            ),
            if (!hintDismissed && list.any((o) => !o.needsReview)) ...[
              const SizedBox(height: 12),
              _Hint(
                onDismiss: () =>
                    ref.read(asNeededHintDismissedProvider.notifier).dismiss(),
              ),
            ],
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, box) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final compact = scale > 1.3 || box.maxWidth < 300;
                final columns = compact
                    ? 1
                    : math.max(
                        2,
                        math.min(
                          widget.maxColumns,
                          (box.maxWidth + 12) ~/ (_minCardWidth + 12),
                        ),
                      );
                const gap = 12.0;
                final width = (box.maxWidth - gap * (columns - 1)) / columns;
                final rows = <Widget>[];
                for (var i = 0; i < list.length; i += columns) {
                  final cells = <Widget>[];
                  for (var c = 0; c < columns; c++) {
                    final index = i + c;
                    if (c > 0) cells.add(const SizedBox(width: gap));
                    cells.add(
                      Expanded(
                        child: index < list.length
                            ? _card(
                                list[index],
                                summaryOf(list[index]),
                                compact: compact,
                                width: width,
                              )
                            : const SizedBox.shrink(),
                      ),
                    );
                  }
                  if (rows.isNotEmpty) rows.add(const SizedBox(height: gap));
                  rows.add(
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: cells,
                      ),
                    ),
                  );
                }
                return Column(children: rows);
              },
            ),
            AnimatedSize(
              duration: AppMotion.quiet(context)
                  ? Duration.zero
                  : AppMotion.standard,
              curve: AppMotion.curve,
              alignment: Alignment.topCenter,
              child: _logOpen
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _Dots(
                        entries: [for (final o in list) (o, summaryOf(o))],
                        emptyStyle: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  /// The section's own space: a card on the tablet, otherwise a block set off
  /// from what is above it.
  Widget _frame(Widget child) => widget.card
      ? TodayCard(key: const ValueKey('as-needed-card'), child: child)
      : Padding(padding: const EdgeInsets.only(top: 24), child: child);

  Widget _card(
    AsNeededOption option,
    AsNeededSummary summary, {
    required bool compact,
    required double width,
  }) => AsNeededRingCard(
    key: ValueKey('as-needed-card-${option.pillId}'),
    option: option,
    summary: summary,
    run: _controller.runOf(option.pillId),
    compact: compact,
    minHeight: math.max(150, width),
    onHoldComplete: () => _hold(option),
    onUndo: () => _controller.undo(option.pillId),
    onDetails: () => _openDetails(option),
    onReview: _openReview,
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.summaries,
    required this.open,
    required this.onToggle,
  });
  final String title;
  final List<(AsNeededOption, AsNeededSummary)> summaries;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    var count = 0;
    DateTime? last;
    for (final (_, s) in summaries) {
      count += s.todayCount;
      final at = s.lastTakenToday;
      if (at != null && (last == null || at.isAfter(last))) last = at;
    }
    final text = count == 0
        ? l.asn_logNone
        : (last == null
              ? l.asn_logLineNoTime(count)
              : l.asn_logLine(count, clockAt(context, last)));
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.headlineSmall),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Semantics(
            button: true,
            expanded: open,
            label: '${l.asn_logToggle}: $text',
            excludeSemantics: true,
            child: InkWell(
              key: const ValueKey('as-needed-log-toggle'),
              borderRadius: BorderRadius.circular(99),
              onTap: onToggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: open ? .5 : 0,
                        duration: AppMotion.quiet(context)
                            ? Duration.zero
                            : AppMotion.standard,
                        curve: AppMotion.curve,
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.entries, required this.emptyStyle});
  final List<(AsNeededOption, AsNeededSummary)> entries;
  final TextStyle? emptyStyle;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final doses =
        <(DateTime?, Color)>[
          for (final (o, s) in entries)
            for (final d in s.todayDoses)
              (d.takenAt, medicationTint(id: o.pill.id, color: o.pill.color)),
        ]..sort((a, b) {
          final x = a.$1;
          final y = b.$1;
          if (x == null) return y == null ? 0 : 1;
          if (y == null) return -1;
          return x.compareTo(y);
        });
    if (doses.isEmpty) return Text(l.asn_noDosesToday, style: emptyStyle);
    return ExcludeSemantics(
      child: Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final (_, color) in doses)
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('as-needed-hint'),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.primary.withValues(alpha: .16),
            ),
            child: Icon(
              Icons.touch_app_outlined,
              size: 19,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.asn_hintTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l.asn_hintBody,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const ValueKey('as-needed-hint-dismiss'),
                    onPressed: onDismiss,
                    child: Text(l.asn_hintGotIt),
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
