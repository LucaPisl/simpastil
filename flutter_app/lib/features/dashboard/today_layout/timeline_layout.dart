import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/medication/care_day.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/scene/scene_clock.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import 'as_needed_entry.dart';
import 'count_header.dart';
import 'day_planner_layout.dart' show plannerMinuteOf;
import 'entry_identity.dart';
import 'low_stock_notice.dart';
import '../today_side/stock_overview.dart' show StockRow;
import 'today_layout.dart';

/// Timeline: the day's doses on one chronological spine.
///
/// Each dose hangs from the spine at its planned time; the capsule on the
/// spine is the same receipt capsule as Focus deck, so a durable take morphs
/// it into a check and sends the one ring out. On the current day the sun sits
/// on the spine where "now" falls, moving once a minute with the sky. Rows
/// expand for amount, zone, sharing and the dose details link. The primary
/// action (Taken now / Undo) is never hidden behind the expansion.
class TimelineLayout extends StatefulWidget {
  const TimelineLayout({super.key, required this.data});
  final TodayLayoutData data;

  @override
  State<TimelineLayout> createState() => _TimelineLayoutState();
}

class _TimelineLayoutState extends State<TimelineLayout> {
  final Set<String> _expanded = {};
  final Map<String, GlobalKey> _keys = {};

  /// Focus this layout asked for itself; only outside requests (the sky)
  /// scroll and expand.
  String? _ownFocus;

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  @override
  void didUpdateWidget(TimelineLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focused = widget.data.focusedId;
    if (focused == null || focused == oldWidget.data.focusedId) return;
    if (focused == _ownFocus) {
      _ownFocus = null;
      return;
    }
    _expanded.add(focused);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[focused]?.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: .2,
        duration: AppMotion.duration(context, milliseconds: 320),
        curve: AppMotion.curve,
      );
    });
  }

  void _toggle(String id) {
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
    _ownFocus = id;
    widget.data.onFocus(id);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final count = SettleHalo(
      token: data.settleToken,
      claim: data.claimMoment,
      onDone: data.onMomentDone,
      child: Semantics(
        liveRegion: data.allRecorded,
        child: RollingLabel(text: data.countLabel(l), style: text.labelLarge),
      ),
    );
    final select = data.onSelectDoses == null
        ? null
        : TextButton.icon(
            key: const ValueKey('timeline-select'),
            onPressed: data.busy ? null : data.onSelectDoses,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              textStyle: text.labelLarge,
            ),
            icon: const Icon(Icons.checklist, size: 19),
            label: Text(l.t10_select),
          );
    return Column(
      key: const ValueKey('timeline-layout'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TodayCountHeader(
          count: count,
          select: select,
          overview: todayOverviewButton(context, data),
          stacked: large,
        ),
        if (data.day.state == CareDayState.recorded && data.hasExpected)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(l.t10_knownOutcomes),
          ),
        const SizedBox(height: 12),
        SceneClock(builder: (context, now) => _spine(context, now)),
        if (data.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                data.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
      ],
    );
  }

  Widget _spine(BuildContext context, DateTime now) {
    final data = widget.data;
    final items = _items(data);
    // The sun appears only on the day it shines on.
    int? nowAt;
    if (routineDateKey(now) == data.day.localDate) {
      nowAt = items.indexWhere((e) => e.at?.isAfter(now) ?? false);
      if (nowAt < 0) nowAt = items.length;
    }
    final rows = <Widget>[];
    // A diamond stop per medication that runs low sits on the spine at now.
    final stops = data.lowStock;
    final total = items.length + (nowAt == null ? 0 : 1) + stops.length;
    var position = 0;
    void addStops() {
      for (final stop in stops) {
        rows.add(
          _LowStockStop(
            key: ValueKey('timeline-stock-${stop.pillId}'),
            row: stop,
            onAddStock: data.onAddStock == null
                ? null
                : () => data.onAddStock!(stop),
            first: position == 0,
            last: position == total - 1,
          ),
        );
        position++;
      }
    }

    if (nowAt == null) addStops();
    for (var i = 0; i <= items.length; i++) {
      if (i == nowAt) {
        rows.add(
          _NowRow(
            key: const ValueKey('timeline-now'),
            now: now,
            first: position == 0,
            last: position == total - 1,
          ),
        );
        position++;
        addStops();
      }
      if (i == items.length) break;
      final item = items[i];
      final entry = item.entry;
      final id = entry.occurrence.id;
      final past =
          nowAt != null && i < nowAt ||
          nowAt == null &&
              data.day.localDate.compareTo(routineDateKey(now)) < 0;
      rows.add(
        KeyedSubtree(
          key: _keyFor(id),
          child: item.record != null
              ? _AsNeededTimelineRow(
                  data: data,
                  record: item.record!,
                  first: position == 0,
                  last: position == total - 1,
                  past: past,
                )
              : _TimelineRow(
                  data: data,
                  entry: entry,
                  expanded: _expanded.contains(id),
                  onToggle: () => _toggle(id),
                  first: position == 0,
                  last: position == total - 1,
                  past: past,
                ),
        ),
      );
      position++;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  /// Scheduled doses in planned order with each recorded as-needed dose placed
  /// at the time it was actually taken; unknown-time ones close the day. Both
  /// sides are compared on the wall clock of their saved zone.
  List<({CareDayEntry entry, AsNeededRecord? record, DateTime? at})> _items(
    TodayLayoutData data,
  ) {
    final scheduled = data.scheduledEntries;
    final items =
        <({CareDayEntry entry, AsNeededRecord? record, DateTime? at})>[
          for (final e in scheduled)
            (entry: e, record: null, at: e.occurrence.plannedAt),
        ];
    final minutes = [
      for (final e in scheduled)
        plannerMinuteOf(data.rowOf(e).plannedLocalTime),
    ];
    for (final r in data.asNeededRecords) {
      final minute = r.minuteOfDay;
      var index = items.length;
      if (minute != null) {
        // Earlier records are already inserted, so later ones land after them.
        final found = items.indexWhere((i) {
          final k = i.record != null
              ? i.record!.minuteOfDay
              : minutes[scheduled.indexOf(i.entry)];
          return k != null && k > minute;
        });
        if (found >= 0) index = found;
      }
      items.insert(index, (entry: r.entry, record: r, at: r.at));
    }
    return items;
  }
}

const double _spineWidth = 36;
const double _nodeTop = 18;
const double _capsuleSize = 26;

/// The spine segment beside one row, with its node position.
class _SpinePainter extends CustomPainter {
  const _SpinePainter({
    required this.color,
    required this.upTo,
    required this.first,
    required this.last,
    required this.rtl,
  });
  final Color color;

  /// The fraction of the segment drawn solid (time already passed).
  final double upTo;
  final bool first, last, rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final x = rtl ? size.width - _spineWidth / 2 : _spineWidth / 2;
    const node = _nodeTop + _capsuleSize / 2;
    final top = first ? node : 0.0;
    final bottom = last ? node : size.height;
    if (bottom <= top) return;
    final solid = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final faint = Paint()
      ..color = color.withValues(alpha: .45)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final split = top + (bottom - top) * upTo.clamp(0, 1);
    if (split > top) canvas.drawLine(Offset(x, top), Offset(x, split), solid);
    // The rest of the day is dashed: not yet happened.
    for (var y = split; y < bottom; y += 9) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, math.min(y + 4.5, bottom)),
        faint,
      );
    }
  }

  @override
  bool shouldRepaint(_SpinePainter old) =>
      old.color != color ||
      old.upTo != upTo ||
      old.first != first ||
      old.last != last ||
      old.rtl != rtl;
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.data,
    required this.entry,
    required this.expanded,
    required this.onToggle,
    required this.first,
    required this.last,
    required this.past,
  });
  final TodayLayoutData data;
  final CareDayEntry entry;
  final bool expanded, first, last, past;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final id = entry.occurrence.id;
    final row = data.rowOf(entry);
    final head = data.headOf(entry);
    final pending = row.state == 'pending';
    final missed = row.state == 'missed';
    final saving = data.isSaving(entry);
    final time = plannedTimeLabel(context, row);
    final state = data.stateLabel(l, entry);
    final travel = data.travelTimeOf(row);

    final receipt = ReceiptSwap.of(row.state, row.stateVersion);
    final status = ReceiptSwap(
      receipt: receipt,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              pending
                  ? Icons.radio_button_unchecked
                  : row.state == 'taken'
                  ? Icons.check_circle
                  : missed
                  ? Icons.error_outline_rounded
                  : Icons.remove_circle_outline,
              size: 16,
              color: semantic.forState(row.state),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                !pending && !missed && head != null
                    ? '$state · ${recordedTimeLabel(context, head, row)}'
                    : state,
                key: ValueKey('timeline-state-$id'),
                style: text.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: semantic.forState(row.state),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final heading = Semantics(
      button: true,
      expanded: expanded,
      liveRegion: !pending,
      label: l.lay_itemLabel(time, entry.snapshot.pillName, state),
      hint: expanded ? l.lay_hideDetails : l.lay_showDetails,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('timeline-item-$id'),
        borderRadius: BorderRadius.circular(16),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      time,
                      style: text.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                        letterSpacing: -.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    EntryMedicationName(
                      entry: entry,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (data.day.people.length != 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: EntryPersonLine(
                          entry: entry,
                          label: l.t08_forPerson(entry.person.name),
                          style: text.labelLarge,
                        ),
                      ),
                    const SizedBox(height: 8),
                    status,
                  ],
                ),
              ),
              AnimatedRotation(
                turns: expanded ? .5 : 0,
                duration: AppMotion.duration(context),
                curve: AppMotion.curve,
                child: Icon(Icons.expand_more, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );

    final actionStyle = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
    Widget? action;
    if (pending || missed) {
      action = SavingPressable(
        saving: saving,
        radius: BorderRadius.circular(14),
        child: FilledButton.icon(
          key: ValueKey('timeline-take-$id'),
          style: actionStyle,
          onPressed: (pending ? data.canTake(entry) : data.canTakeLate(entry))
              ? () => data.onTake(entry)
              : null,
          icon: const Icon(Icons.check_circle_outline),
          label: Text(
            saving
                ? l.sc_saving
                : missed
                ? l.dose_takeLateNow
                : l.t08_takenNow,
          ),
        ),
      );
    } else if (data.offersUndo(entry)) {
      action = SavingPressable(
        saving: saving,
        radius: BorderRadius.circular(14),
        child: OutlinedButton.icon(
          key: ValueKey('timeline-undo-$id'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: data.canUndo(entry) ? () => data.onUndo(entry) : null,
          icon: const Icon(Icons.undo),
          label: Text(saving ? l.sc_saving : l.t08_undo),
        ),
      );
    }

    // A missed dose can be taken late or withdrawn; the rest of the row
    // actions stay where they are for every other state.
    if (missed && action != null) {
      action = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          action,
          const SizedBox(height: 8),
          SavingPressable(
            saving: saving,
            radius: BorderRadius.circular(14),
            child: OutlinedButton.icon(
              key: ValueKey('timeline-undo-$id'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: data.canUndo(entry) ? () => data.onUndo(entry) : null,
              icon: const Icon(Icons.undo),
              label: Text(saving ? l.sc_saving : l.t08_undo),
            ),
          ),
        ],
      );
    }

    final details = Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            plannedAmountLabel(l, entry),
            style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
          ),
          if (entry.snapshot.dosage?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(entry.snapshot.dosage!, style: text.bodyMedium),
            ),
          if (travel != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(travel, style: text.bodySmall),
            ),
          if (pending && data.day.state == CareDayState.laterDue)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l.t08_later, style: text.bodySmall),
            ),
          ReceiptSwap(
            receipt: receipt,
            child: pending
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: DurableSaveFeedback(
                      label: todaySharingLabel(l, data.sharingOf(entry)),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('timeline-details-$id'),
              onPressed: data.busy ? null : () => data.onOpenDetails(entry),
              icon: const Icon(Icons.more_horiz),
              label: Text(l.t10_details),
            ),
          ),
        ],
      ),
    );

    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: data.focusedId == id
              ? colors.primary.withValues(alpha: .55)
              : colors.outlineVariant.withValues(alpha: .5),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heading,
            AnimatedSize(
              duration: AppMotion.duration(context),
              curve: AppMotion.curve,
              alignment: Alignment.topCenter,
              child: expanded
                  ? details
                  : const SizedBox(width: double.infinity),
            ),
            ReceiptSwap(
              receipt: receipt,
              child: action == null
                  ? null
                  : Padding(
                      padding: EdgeInsets.fromLTRB(14, large ? 4 : 0, 14, 14),
                      child: action,
                    ),
            ),
          ],
        ),
      ),
    );

    // The receipt ring reaches past the row onto the page margin; the
    // capsule limits its own reach to the screen edge.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _SpinePainter(
              color: colors.primary,
              upTo: past ? 1 : 0,
              first: first,
              last: last,
              rtl: rtl,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: _spineWidth + 6,
            bottom: last ? 0 : 12,
          ),
          child: card,
        ),
        PositionedDirectional(
          start: (_spineWidth - _capsuleSize) / 2,
          top: _nodeTop,
          child: ReceiptCapsule(
            key: ValueKey('timeline-capsule-$id'),
            taken: row.state == 'taken',
            moment: data.momentOf(id),
            claim: data.claimMoment,
            onDone: data.onMomentDone,
          ),
        ),
      ],
    );
  }
}

/// A recorded as-needed dose on the spine at the time it was taken. Its node
/// is the medication's own mark rather than a receipt capsule: nothing here is
/// scheduled, so there is nothing to take or undo (the ring card does that).
class _AsNeededTimelineRow extends StatelessWidget {
  const _AsNeededTimelineRow({
    required this.data,
    required this.record,
    required this.first,
    required this.last,
    required this.past,
  });
  final TodayLayoutData data;
  final AsNeededRecord record;
  final bool first, last, past;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _SpinePainter(
              color: colors.primary,
              upTo: past ? 1 : 0,
              first: first,
              last: last,
              rtl: rtl,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: _spineWidth + 6,
            bottom: last ? 0 : 12,
          ),
          child: AsNeededRecordTile(
            data: data,
            record: record,
            showPerson: data.day.people.length != 1,
          ),
        ),
        PositionedDirectional(
          start: (_spineWidth - _capsuleSize) / 2,
          top: _nodeTop,
          child: ExcludeSemantics(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surface,
              ),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: EntryMedicationMark(entry: record.entry, size: 20),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sun on the spine where "now" falls; it says the time in words.
class _NowRow extends ConsumerWidget {
  const _NowRow({
    super.key,
    required this.now,
    required this.first,
    required this.last,
  });
  final DateTime now;
  final bool first, last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final highContrast =
        ref.watch(highContrastEnabledProvider) ||
        MediaQuery.highContrastOf(context);
    final time = TimeOfDay.fromDateTime(now).format(context);
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _SpinePainter(
              color: theme.colorScheme.primary,
              upTo: .5,
              first: first,
              last: last,
              rtl: Directionality.of(context) == TextDirection.rtl,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: _spineWidth + 6,
            top: _nodeTop - 2,
            bottom: last ? 0 : 14,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 30),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                l.lay_now(time),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
        PositionedDirectional(
          start: (_spineWidth - 30) / 2,
          top: _nodeTop - 2,
          child: ExcludeSemantics(
            child: CustomPaint(
              size: const Size.square(30),
              painter: _SunPainter(
                fill: highContrast ? null : const Color(0xFFFFC27A),
                outline: highContrast
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.outline,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A medication that runs low, as a diamond stop on the spine (where "now"
/// sits) with the notice beside it. Informational: it adds no dose.
class _LowStockStop extends StatelessWidget {
  const _LowStockStop({
    super.key,
    required this.row,
    required this.onAddStock,
    required this.first,
    required this.last,
  });
  final StockRow row;
  final VoidCallback? onAddStock;
  final bool first, last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = lowStockInk(context);
    const diamond = 14.0;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _SpinePainter(
              color: theme.colorScheme.primary,
              upTo: 0,
              first: first,
              last: last,
              rtl: Directionality.of(context) == TextDirection.rtl,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: _spineWidth + 6,
            top: 6,
            bottom: last ? 0 : 10,
          ),
          child: LowStockLine(row: row, onAddStock: onAddStock),
        ),
        PositionedDirectional(
          start: (_spineWidth - diamond) / 2,
          top: _nodeTop + (_capsuleSize - diamond) / 2 - 8,
          child: ExcludeSemantics(
            child: Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                width: diamond,
                height: diamond,
                decoration: BoxDecoration(
                  color: ink,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 2,
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

class _SunPainter extends CustomPainter {
  const _SunPainter({required this.fill, required this.outline});
  final Color? fill;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * .25;
    final rays = Paint()
      ..color = fill ?? outline
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * (r + 3.5), c + d * (r + 7), rays);
    }
    if (fill != null) canvas.drawCircle(c, r, Paint()..color = fill!);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = outline,
    );
  }

  @override
  bool shouldRepaint(_SunPainter old) =>
      old.fill != fill || old.outline != outline;
}
