import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/db/database.dart' show Profile;
import '../../../core/medication/care_day.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import '../../../shared/widgets/person_avatar.dart';
import 'as_needed_entry.dart';
import 'count_header.dart';
import 'dose_weight.dart';
import 'entry_identity.dart';
import '../today_side/stock_overview.dart' show StockRow;
import 'low_stock_notice.dart';
import 'today_layout.dart';

/// People lanes: the day's care grouped by person.
///
/// Every person with scheduled care today gets a lane of their own: an avatar
/// wrapped in a progress ring with the count in words beside it ("Casey ·
/// 1 of 3 taken"), then that person's doses in time order. Each dose carries
/// the same receipt capsule as Focus deck, so a durable take plays the same
/// moment. Lanes sit side by side only on wide screens with ordinary text;
/// on phones and with large text they stack. With one person the lane is the
/// whole page and its header grows, so the arrangement still reads as chosen.
/// The person's name is part of every action's spoken label.
class PeopleLanesLayout extends StatefulWidget {
  const PeopleLanesLayout({super.key, required this.data});
  final TodayLayoutData data;

  @override
  State<PeopleLanesLayout> createState() => _PeopleLanesLayoutState();
}

class _Lane {
  _Lane(this.person);
  final Profile person;
  final List<CareDayEntry> entries = [];

  /// Recorded as-needed doses of this person, earliest first. They are never
  /// part of the scheduled count.
  final List<AsNeededRecord> records = [];
}

class _PeopleLanesLayoutState extends State<PeopleLanesLayout> {
  final Set<String> _expanded = {};
  final Map<String, GlobalKey> _keys = {};

  /// Focus this layout asked for itself; only outside requests (the sky)
  /// scroll and expand.
  String? _ownFocus;

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  @override
  void didUpdateWidget(PeopleLanesLayout oldWidget) {
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

  /// Lanes in the day's person order; doses keep the day's planned order.
  List<_Lane> _lanes() {
    final data = widget.data;
    final lanes = <String, _Lane>{
      for (final person in data.day.people) person.id: _Lane(person),
    };
    for (final entry in data.scheduledEntries) {
      lanes
          .putIfAbsent(entry.person.id, () => _Lane(entry.person))
          .entries
          .add(entry);
    }
    for (final record in data.asNeededRecords) {
      lanes
          .putIfAbsent(record.entry.person.id, () => _Lane(record.entry.person))
          .records
          .add(record);
    }
    return [
      for (final lane in lanes.values)
        if (lane.entries.isNotEmpty || lane.records.isNotEmpty) lane,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final lanes = _lanes();
    final solo = lanes.length == 1;
    final identity = 'people-lanes/${data.day.localDate}';

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
            key: const ValueKey('lanes-select'),
            onPressed: data.busy ? null : data.onSelectDoses,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              textStyle: text.labelLarge,
            ),
            icon: const Icon(Icons.checklist, size: 19),
            label: Text(l.t10_select),
          );

    var tileIndex = 0;
    Widget laneWidget(_Lane lane, int laneIndex) {
      final tiles = <Widget>[];
      for (final entry in lane.entries) {
        final id = entry.occurrence.id;
        tiles.add(
          StaggeredEntrance(
            index: laneIndex + (++tileIndex),
            identity: identity,
            child: KeyedSubtree(
              key: _keyFor(id),
              child: _DoseTile(
                data: data,
                entry: entry,
                expanded: _expanded.contains(id),
                onToggle: () => _toggle(id),
              ),
            ),
          ),
        );
      }
      for (final record in lane.records) {
        tiles.add(
          StaggeredEntrance(
            index: laneIndex + (++tileIndex),
            identity: identity,
            child: KeyedSubtree(
              key: _keyFor(record.entry.occurrence.id),
              child: AsNeededRecordTile(
                data: data,
                record: record,
                showPerson: false,
              ),
            ),
          ),
        );
      }
      return StaggeredEntrance(
        index: laneIndex,
        identity: identity,
        child: _LaneCard(
          data: data,
          lane: lane,
          solo: solo,
          tiles: tiles,
          lowStock: [
            for (final row in data.lowStock)
              if (row.personId == lane.person.id) row,
          ],
        ),
      );
    }

    // A medication that runs low for someone with no dose on this day still
    // gets its notice, under the lanes.
    final laneOwners = {for (final lane in lanes) lane.person.id};
    final unplaced = [
      for (final row in data.lowStock)
        if (!laneOwners.contains(row.personId)) row,
    ];

    final laneWidgets = [
      for (var i = 0; i < lanes.length; i++) laneWidget(lanes[i], i),
    ];

    return Column(
      key: const ValueKey('people-lanes-layout'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TodayCountHeader(
          count: count,
          select: select,
          overview: todayOverviewButton(context, data),
          stacked: large,
        ),
        if (data.showsKnownOutcomes)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(l.t10_knownOutcomes),
          ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            // Side by side only when every lane keeps a comfortable width.
            final side =
                !large &&
                lanes.length > 1 &&
                constraints.maxWidth / math.min(lanes.length, 3) >= 300;
            if (!side) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < laneWidgets.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: i == laneWidgets.length - 1 ? 0 : 16,
                      ),
                      child: laneWidgets[i],
                    ),
                ],
              );
            }
            final perRow = math.min(lanes.length, 3);
            final rows = <Widget>[];
            for (var start = 0; start < laneWidgets.length; start += perRow) {
              final slice = laneWidgets.skip(start).take(perRow).toList();
              rows.add(
                Padding(
                  padding: EdgeInsets.only(
                    bottom: start + perRow >= laneWidgets.length ? 0 : 16,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < perRow; i++) ...[
                        if (i > 0) const SizedBox(width: 16),
                        Expanded(
                          child: i < slice.length
                              ? slice[i]
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            );
          },
        ),
        for (final row in unplaced)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: lowStockRowFor(row, data.onAddStock, data.onDismissLowStock),
          ),
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
}

/// Taken and expected scheduled doses of one lane, following stored receipts.
/// As-needed doses are never counted here (see `_Lane.records`).
({int taken, int total}) _laneCount(TodayLayoutData data, _Lane lane) {
  final expected = lane.entries.where((e) => e.occurrence.expected).toList();
  final counted = expected.isEmpty ? lane.entries : expected;
  return (
    taken: counted.where((e) => data.rowOf(e).state == 'taken').length,
    total: counted.length,
  );
}

class _LaneCard extends StatelessWidget {
  const _LaneCard({
    required this.data,
    required this.lane,
    required this.solo,
    required this.tiles,
    required this.lowStock,
  });
  final TodayLayoutData data;
  final _Lane lane;
  final bool solo;
  final List<Widget> tiles;

  /// Medication of this person that runs low, drawn inside the lane.
  final List<StockRow> lowStock;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final person = lane.person;
    final (:taken, :total) = _laneCount(data, lane);
    // Before anything is due and with nothing recorded, "0 of 1 taken" reads
    // like a miss; say what is true instead. Counts stay as they are after.
    final asNeeded = lane.records.length;
    final scheduled =
        taken == 0 && total > 0 && data.day.state == CareDayState.laterDue
        ? l.lay_nothingDueYet
        : l.widget_summary(taken, total);
    // "2 of 3 taken · 1 as needed"; a lane with only as-needed doses just says
    // "1 as needed", never "1 of 1 taken".
    final summary = total == 0
        ? l.lay_asNeededCount(asNeeded)
        : asNeeded == 0
        ? scheduled
        : '$scheduled · ${l.lay_asNeededCount(asNeeded)}';
    final done = total > 0 && taken == total;
    final avatarSize = solo ? 64.0 : 52.0;

    final avatar = _AvatarRing(
      key: ValueKey('lanes-ring-${person.id}'),
      size: avatarSize,
      person: person,
      taken: taken,
      total: total,
      // Only a take the person just made (a durable receipt moment on one of
      // this lane's doses) may pop the ring; a sync that completes the day
      // fills it quietly.
      momentToken: lane.entries
          .map((e) => data.momentOf(e.occurrence.id))
          .where((m) => m != null && !m.undo)
          .map((m) => m!.token)
          .firstOrNull,
    );
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          person.name,
          style: (solo ? text.headlineSmall : text.titleLarge)?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -.3,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (done) ...[
              Icon(
                Icons.check_circle,
                size: 16,
                color: theme.extension<AppSemanticColors>()!.statusTaken,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: RollingLabel(
                key: ValueKey('lanes-summary-${person.id}'),
                text: summary,
                style: text.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
    final header = Semantics(
      header: true,
      container: true,
      excludeSemantics: true,
      label: '${person.name} · $summary',
      child: large
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [avatar, const SizedBox(height: 10), words],
            )
          : Row(
              children: [
                avatar,
                const SizedBox(width: 14),
                Expanded(child: words),
              ],
            ),
    );

    return Container(
      key: ValueKey('lanes-lane-${person.id}'),
      padding: EdgeInsets.fromLTRB(14, solo ? 18 : 14, 14, 14),
      decoration: BoxDecoration(
        // A quiet lavender wash; status never rides on this colour.
        color: Color.alphaBlend(
          colors.primaryContainer.withValues(alpha: .55),
          colors.surface,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colors.primary.withValues(alpha: .14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          SizedBox(height: solo ? 18 : 14),
          for (var i = 0; i < tiles.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == tiles.length - 1 ? 0 : 10),
              child: tiles[i],
            ),
          for (final row in lowStock)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: lowStockRowFor(
                row,
                data.onAddStock,
                data.onDismissLowStock,
              ),
            ),
        ],
      ),
    );
  }
}

/// The person's avatar inside a ring of one segment per dose that fills, in
/// sage, as their doses are taken. The count in words sits beside it, so the
/// ring only adds to it. A finished day gives the ring one soft pop, and only
/// when a take made here finishes it (never on first build, rebuild or sync).
class _AvatarRing extends StatefulWidget {
  const _AvatarRing({
    super.key,
    required this.size,
    required this.person,
    required this.taken,
    required this.total,
    required this.momentToken,
  });
  final double size;
  final Profile person;
  final int taken;
  final int total;

  /// The token of the receipt moment of a take made here, if one is live.
  final String? momentToken;

  @override
  State<_AvatarRing> createState() => _AvatarRingState();
}

class _AvatarRingState extends State<_AvatarRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 860),
  );

  /// The moment token this ring may still pop for; spent once it has.
  String? _armed;

  bool _done(_AvatarRing w) => w.total > 0 && w.taken >= w.total;

  @override
  void didUpdateWidget(_AvatarRing old) {
    super.didUpdateWidget(old);
    final token = widget.momentToken;
    if (token != null && token != old.momentToken) _armed = token;
    if (token == null) _armed = null;
    // One pop per take made here: armed by its receipt moment, spent when
    // the ring closes (or already closed), so a sync finishing the day while
    // the same moment is live cannot pop it a second time.
    if (_armed != null && _done(widget)) {
      _armed = null;
      if (!AppMotion.quiet(context)) _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final sage = theme.extension<AppSemanticColors>()!.statusTaken;
    final total = widget.total;
    return ExcludeSemantics(
      child: ScaleTransition(
        scale: TweenSequence<double>([
          // The ring closes first (520 ms); the pop lands as it does.
          TweenSequenceItem(tween: ConstantTween(1.0), weight: 45),
          TweenSequenceItem(
            tween: Tween(
              begin: 1.0,
              end: 1.09,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 20,
          ),
          TweenSequenceItem(
            tween: Tween(
              begin: 1.09,
              end: 1.0,
            ).chain(CurveTween(curve: Curves.easeInOut)),
            weight: 35,
          ),
        ]).animate(_pop),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: total == 0 ? 0 : widget.taken / total),
          duration: AppMotion.duration(context, milliseconds: 520),
          curve: AppMotion.curve,
          builder: (context, value, child) => CustomPaint(
            painter: _RingPainter(
              progress: value,
              segments: total,
              track: colors.primary.withValues(alpha: .16),
              fill: sage,
            ),
            child: child,
          ),
          child: SizedBox.square(
            dimension: widget.size,
            child: Padding(
              padding: const EdgeInsets.all(6),
              // The person's own face and tint, as on People and the picker.
              child: PersonAvatar(
                key: ValueKey('lanes-face-${widget.person.id}'),
                id: widget.person.id,
                name: widget.person.name,
                emoji: widget.person.avatarEmoji,
                size: widget.size - 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.segments,
    required this.track,
    required this.fill,
  });
  final double progress;

  /// One segment per dose up to [maxSegments]; beyond that, one plain ring.
  final int segments;
  final Color track, fill;

  static const maxSegments = 12;
  static const _gap = .2;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.5;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final n = segments > 1 && segments <= maxSegments ? segments : 1;
    final gap = n > 1 ? _gap : 0.0;
    final sweepEach = (math.pi * 2 - gap * n) / n;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = n > 1 ? StrokeCap.butt : StrokeCap.round;
    final filled = progress.clamp(0.0, 1.0) * n;
    for (var i = 0; i < n; i++) {
      final start = -math.pi / 2 + gap / 2 + i * (sweepEach + gap);
      canvas.drawArc(rect, start, sweepEach, false, paint..color = track);
      final share = (filled - i).clamp(0.0, 1.0);
      if (share > 0) {
        canvas.drawArc(
          rect,
          start,
          sweepEach * share,
          false,
          paint..color = fill,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.segments != segments ||
      old.track != track ||
      old.fill != fill;
}

class _DoseTile extends StatelessWidget {
  const _DoseTile({
    required this.data,
    required this.entry,
    required this.expanded,
    required this.onToggle,
  });
  final TodayLayoutData data;
  final CareDayEntry entry;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final id = entry.occurrence.id;
    final row = data.rowOf(entry);
    final head = data.headOf(entry);
    final pending = row.state == 'pending';
    final missed = row.state == 'missed';
    final time = plannedTimeLabel(context, row);
    final state = data.stateLabel(l, entry);
    final travel = data.travelTimeOf(row);
    final forPerson = l.t08_forPerson(entry.person.name);

    final receipt = ReceiptSwap.of(row.state, row.stateVersion);
    final status = ReceiptSwap(
      receipt: receipt,
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
              key: ValueKey('lanes-state-$id'),
              style: text.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: semantic.forState(row.state),
              ),
            ),
          ),
        ],
      ),
    );

    final capsule = ReceiptCapsule(
      key: ValueKey('lanes-capsule-$id'),
      taken: row.state == 'taken',
      moment: data.momentOf(id),
      claim: data.claimMoment,
      onDone: data.onMomentDone,
    );

    final heading = Semantics(
      button: true,
      expanded: expanded,
      liveRegion: !pending,
      label:
          '${l.lay_itemLabel(time, entry.snapshot.pillName, state)}, '
          '$forPerson',
      hint: expanded ? l.lay_hideDetails : l.lay_showDetails,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('lanes-item-$id'),
        borderRadius: BorderRadius.circular(16),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: capsule),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      time,
                      style: text.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                        letterSpacing: -.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    EntryMedicationName(
                      entry: entry,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
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

    final action = doseActions(data, entry, prefix: 'lanes', hint: forPerson);

    final details = Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
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
              key: ValueKey('lanes-details-$id'),
              onPressed: data.busy ? null : () => data.onOpenDetails(entry),
              icon: const Icon(Icons.more_horiz),
              label: Text(l.t10_details),
            ),
          ),
        ],
      ),
    );

    final folded = expanded ? details : const SizedBox(width: double.infinity);
    // A zero-length AnimatedSize re-dirties itself mid-layout, so Reduce
    // motion takes the plain child.
    final expansion = AppMotion.quiet(context)
        ? folded
        : AnimatedSize(
            duration: AppMotion.standard,
            curve: AppMotion.curve,
            alignment: Alignment.topCenter,
            child: folded,
          );
    // A taken or skipped dose shrinks to one quiet line with a text Undo, so
    // it never outweighs the dose still to take.
    final body = data.showsDone(entry)
        ? Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 4, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                QuietDoneLine(
                  data: data,
                  entry: entry,
                  prefix: 'lanes',
                  leading: capsule,
                  onTap: onToggle,
                  expanded: expanded,
                  time: true,
                ),
                expansion,
              ],
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              heading,
              expansion,
              if (action != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(12, large ? 4 : 0, 12, 12),
                  child: action,
                ),
            ],
          );

    final focused = data.focusedId == id;
    return AnimatedContainer(
      duration: AppMotion.duration(context),
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          width: focused ? 1.5 : 1,
          color: focused
              ? colors.primary.withValues(alpha: .6)
              : colors.outlineVariant.withValues(alpha: .45),
        ),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ReceiptSwap(receipt: data.swapKeyOf(entry), child: body),
      ),
    );
  }
}
