import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/medication/care_day.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import 'as_needed_entry.dart';
import 'count_header.dart';
import 'dose_weight.dart';
import 'entry_identity.dart';
import 'low_stock_notice.dart';
import '../today_side/stock_overview.dart' show StockRow;
import 'today_layout.dart';

/// Action inbox: what still needs recording first, recorded doses apart.
///
/// Two sections, "Needs you" and "Recorded today". A durable take (or undo)
/// makes the dose travel to the other section (one row, measured slide), and
/// keyboard or screen-reader focus follows it to the matching action, so focus
/// is never lost with the row it was on. A line under the count says the move
/// in words.
class ActionInboxLayout extends StatefulWidget {
  const ActionInboxLayout({super.key, required this.data});
  final TodayLayoutData data;

  @override
  State<ActionInboxLayout> createState() => _ActionInboxLayoutState();
}

class _ActionInboxLayoutState extends State<ActionInboxLayout> {
  /// One focus node per action button, keyed `take/<id>` or `undo/<id>`.
  final Map<String, FocusNode> _nodes = {};

  /// Occurrence this layout recorded or undid; focus follows it once it moves.
  String? _acted;
  String? _moveNote;

  /// Which section each dose was last built in (the data's callbacks read
  /// live deck state, so an older widget cannot answer this).
  final Map<String, bool> _lastNeeds = {};

  /// The column every part travels within.
  final GlobalKey _space = GlobalKey(debugLabel: 'inbox-space');

  FocusNode _node(String key) =>
      _nodes.putIfAbsent(key, () => FocusNode(debugLabel: 'inbox-$key'));

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  bool _needs(CareDayEntry e, TodayLayoutData data) => data.isPending(e);

  @override
  void didUpdateWidget(ActionInboxLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A taken moment that just settled: its button gives way to the quiet
    // line, so focus moves on to that line's Undo.
    for (final settled in oldWidget.data.morphs.keys) {
      if (widget.data.morphs.containsKey(settled)) continue;
      if (_nodes['take/$settled']?.hasFocus != true) continue;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final node = _nodes['undo/$settled'];
        if (mounted && node?.context != null && node!.canRequestFocus) {
          node.requestFocus();
        }
      });
    }
    final id = _acted;
    if (id == null) return;
    CareDayEntry? entry;
    for (final e in widget.data.entries) {
      if (e.occurrence.id == id) entry = e;
    }
    if (entry == null) return;
    final before = _lastNeeds[id];
    final now = _needs(entry, widget.data);
    if (before == null || before == now) return;
    _acted = null;
    final l = AppLocalizations.of(context);
    final name = entry.snapshot.pillName;
    _moveNote = now ? l.ibx_movedNeeds(name) : l.ibx_movedRecorded(name);
    // The moved row mounts in the other section on this frame; hand focus to
    // its counterpart action once it exists.
    // While the taken moment plays, the pressed button is the dose's Undo.
    final key = now || widget.data.isMorphing(entry) ? 'take/$id' : 'undo/$id';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The shared place follows the dose the user just acted on.
      widget.data.onFocus(id);
      final node = _nodes[key];
      if (node != null && node.context != null && node.canRequestFocus) {
        node.requestFocus();
      }
    });
  }

  void _take(CareDayEntry entry) {
    _acted = entry.occurrence.id;
    widget.data.onTake(entry);
  }

  void _undo(CareDayEntry entry) {
    _acted = entry.occurrence.id;
    widget.data.onUndo(entry);
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
            key: const ValueKey('inbox-select'),
            onPressed: data.busy ? null : data.onSelectDoses,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              textStyle: text.labelLarge,
            ),
            icon: const Icon(Icons.checklist, size: 19),
            label: Text(l.t10_select),
          );
    // As-needed doses are never something to do: only recorded ones appear,
    // under Recorded today with an "As needed" tag.
    final scheduled = data.scheduledEntries;
    for (final e in scheduled) {
      _lastNeeds[e.occurrence.id] = _needs(e, data);
    }
    final needs = [
      for (final e in scheduled)
        if (_needs(e, data)) e,
    ];
    final recorded = [
      for (final e in scheduled)
        if (!_needs(e, data)) e,
    ];
    final asNeeded = data.asNeededRecords;
    // Both sections are one column of keyed parts, so a dose that changes
    // section keeps its element and travels from its old place to its new
    // one (see [_Travel]) instead of fading out here and in there.
    final quiet = AppMotion.quiet(context);
    Widget travel(Key key, Widget child) =>
        _Travel(key: key, space: _space, enabled: !quiet, child: child);
    Iterable<Widget> section({
      required bool isNeeds,
      required String title,
      required String empty,
      required List<CareDayEntry> rows,
      List<AsNeededRecord> records = const [],
      List<StockRow> stock = const [],
    }) sync* {
      final tag = isNeeds ? 'needs' : 'rec';
      yield travel(
        ValueKey('inbox-heading-wrap-$tag'),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Semantics(
            header: true,
            child: Text(
              '$title · ${rows.length + records.length + stock.length}',
              key: ValueKey('inbox-heading-$tag'),
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
      for (final row in stock) {
        yield travel(
          ValueKey('inbox-stock-${row.pillId}'),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: lowStockRowFor(row, data.onAddStock, data.onDismissLowStock),
          ),
        );
      }
      if (rows.isEmpty && records.isEmpty && stock.isEmpty) {
        yield travel(
          ValueKey('inbox-empty-$tag'),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(empty, style: text.bodyMedium),
          ),
        );
      }
      for (var i = 0; i < rows.length; i++) {
        final id = rows[i].occurrence.id;
        yield travel(
          ValueKey('inbox-item-$id'),
          StaggeredEntrance(
            index: data.entries.indexOf(rows[i]),
            identity: 'inbox-${data.day.localDate}',
            child: _InboxRow(
              data: data,
              entry: rows[i],
              needs: isNeeds,
              takeNode: _node('take/$id'),
              undoNode: _node('undo/$id'),
              onTake: _take,
              onUndo: _undo,
            ),
          ),
        );
      }
      for (var i = 0; i < records.length; i++) {
        final id = records[i].entry.occurrence.id;
        yield travel(
          ValueKey('inbox-item-$id'),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: StaggeredEntrance(
              index: data.entries.length + i,
              identity: 'inbox-${data.day.localDate}',
              child: AsNeededRecordTile(data: data, record: records[i]),
            ),
          ),
        );
      }
    }

    return KeyedSubtree(
      key: const ValueKey('inbox-layout'),
      child: Column(
        key: _space,
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
          if (_moveNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _moveNote!,
                  key: const ValueKey('inbox-move-note'),
                  style: text.bodySmall,
                ),
              ),
            ),
          const SizedBox(height: 12),
          ...section(
            isNeeds: true,
            title: l.ibx_needsYou,
            empty: l.ibx_needsNone,
            rows: needs,
            stock: data.lowStock,
          ),
          const SizedBox(key: ValueKey('inbox-gap'), height: 8),
          ...section(
            isNeeds: false,
            title: l.ibx_recordedToday,
            empty: l.ibx_recordedNone,
            rows: recorded,
            records: asNeeded,
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
      ),
    );
  }
}

/// Measured travel (first, last, invert, play): after a layout pass moves
/// this part within [space], it is painted where it was on the previous frame
/// and glides to its new place, so a dose changing section visibly travels
/// from "Needs you" to "Recorded today". Scrolling never moves a part within
/// [space], so it never animates. Hit tests, focus highlights and semantics
/// follow the painted position. Disabled (quiet mode) it lays out in place.
class _Travel extends StatefulWidget {
  const _Travel({
    super.key,
    required this.space,
    required this.enabled,
    required this.child,
  });
  final GlobalKey space;
  final bool enabled;
  final Widget child;

  static const duration = Duration(milliseconds: 420);

  @override
  State<_Travel> createState() => _TravelState();
}

class _TravelState extends State<_Travel> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _Travel.duration,
    value: 1,
  );

  void _play() {
    if (mounted) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _TravelBox(
    space: widget.space,
    enabled: widget.enabled,
    progress: _c,
    onMoved: _play,
    child: widget.child,
  );
}

class _TravelBox extends SingleChildRenderObjectWidget {
  const _TravelBox({
    required this.space,
    required this.enabled,
    required this.progress,
    required this.onMoved,
    super.child,
  });
  final GlobalKey space;
  final bool enabled;
  final Animation<double> progress;
  final VoidCallback onMoved;

  @override
  _RenderTravel createRenderObject(BuildContext context) => _RenderTravel(
    space: space,
    enabled: enabled,
    progress: progress,
    onMoved: onMoved,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderTravel renderObject) {
    renderObject
      ..space = space
      ..enabled = enabled
      ..progress = progress
      ..onMoved = onMoved;
  }
}

class _RenderTravel extends RenderProxyBox {
  _RenderTravel({
    required this.space,
    required this.enabled,
    required Animation<double> progress,
    required this.onMoved,
  }) : _progress = progress;

  GlobalKey space;
  bool enabled;
  VoidCallback onMoved;
  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (value == _progress) return;
    if (attached) _progress.removeListener(markNeedsPaint);
    _progress = value;
    if (attached) _progress.addListener(markNeedsPaint);
  }

  /// Layout position within [space] at the last paint.
  Offset? _last;

  /// Offset from the layout position at the start of the current travel.
  Offset _from = Offset.zero;

  /// A travel was measured this frame; it starts on the next tick.
  bool _starting = false;

  Offset get _shift {
    if (_starting) return _from;
    final t = Curves.easeInOutCubic.transform(_progress.value);
    return _from * (1 - t);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _progress.removeListener(markNeedsPaint);
    super.detach();
  }

  Offset? _measure() {
    final ancestor = space.currentContext?.findRenderObject();
    if (ancestor is! RenderBox || !ancestor.attached) return null;
    for (RenderObject? node = parent; node != null; node = node.parent) {
      if (identical(node, ancestor)) {
        return localToGlobal(Offset.zero, ancestor: ancestor);
      }
    }
    return null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final here = _measure();
    final last = _last;
    if (here != null) {
      // Small steps come from neighbours easing their own size; only a
      // real change of place travels.
      if (enabled && last != null && (here - last).distance > 24) {
        // Start from where it is drawn now, even mid-travel.
        _from = last + _shift - here;
        if (!_starting) {
          _starting = true;
          SchedulerBinding.instance.addPostFrameCallback((_) {
            _starting = false;
            if (attached) onMoved();
          });
        }
      } else if (!enabled) {
        _from = Offset.zero;
      }
      _last = here;
    }
    final child = this.child;
    if (child != null) context.paintChild(child, offset + _shift);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _shift,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final shift = _shift;
    transform.translateByDouble(shift.dx, shift.dy, 0, 1);
  }
}

class _InboxRow extends StatelessWidget {
  const _InboxRow({
    required this.data,
    required this.entry,
    required this.needs,
    required this.takeNode,
    required this.undoNode,
    required this.onTake,
    required this.onUndo,
  });
  final TodayLayoutData data;
  final CareDayEntry entry;
  final bool needs;
  final FocusNode takeNode, undoNode;
  final void Function(CareDayEntry) onTake, onUndo;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final id = entry.occurrence.id;
    final row = data.rowOf(entry);
    final head = data.headOf(entry);
    final pending = row.state == 'pending';
    final missed = row.state == 'missed';
    final time = plannedTimeLabel(context, row);
    final state = data.stateLabel(l, entry);
    final travel = data.travelTimeOf(row);
    final stateColor = semantic.forState(row.state);
    final receipt = ReceiptSwap.of(row.state, row.stateVersion);
    // The card and its action keep the key from before a take while the
    // button plays its moment; the state words follow the receipt at once.
    final hold = data.swapKeyOf(entry);
    final stateText = !pending && !missed && head != null
        ? '$state · ${recordedTimeLabel(context, head, row)}'
        : state;

    final action = doseActions(
      data,
      entry,
      prefix: 'inbox',
      onTake: onTake,
      onUndo: onUndo,
      takeNode: takeNode,
      undoNode: undoNode,
    );
    final capsule = ReceiptCapsule(
      key: ValueKey('inbox-capsule-$id'),
      taken: row.state == 'taken',
      moment: data.momentOf(id),
      claim: data.claimMoment,
      onDone: data.onMomentDone,
    );
    void openDetails() {
      data.onFocus(id);
      data.onOpenDetails(entry);
    }

    final border = Border.all(
      color: data.focusedId == id
          ? colors.primary.withValues(alpha: .55)
          : colors.outlineVariant.withValues(alpha: .5),
    );

    // A taken or skipped dose shrinks to one quiet line with a text Undo;
    // tapping it opens the dose's details.
    if (data.showsDone(entry)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ReceiptSwap(
          receipt: hold,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(18),
              border: border,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 2, 2, 2),
                child: QuietDoneLine(
                  data: data,
                  entry: entry,
                  prefix: 'inbox',
                  leading: capsule,
                  onTap: data.busy ? null : openDetails,
                  itemKey: false,
                  time: true,
                  person: data.day.people.length != 1,
                  onUndo: onUndo,
                  undoNode: undoNode,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final title = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 12, top: 2),
          child: capsule,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EntryMedicationName(
                entry: entry,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                '$time · ${plannedAmountLabel(l, entry)}',
                style: text.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              if (data.day.people.length != 1)
                EntryPersonLine(
                  entry: entry,
                  label: l.t08_forPerson(entry.person.name),
                  style: text.bodyMedium,
                ),
              if (travel != null) Text(travel, style: text.bodySmall),
              const SizedBox(height: 6),
              // State words, action and sharing line share one receipt key:
              // they change together, never Undo before Taken.
              ReceiptSwap(
                receipt: receipt,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stateText,
                      key: ValueKey('inbox-state-$id'),
                      style: text.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: stateColor,
                      ),
                    ),
                    // As on the Focus deck: nothing is due yet, so the row
                    // says it is coming up rather than reading as overdue.
                    if (pending && data.day.state == CareDayState.laterDue)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          l.t08_later,
                          key: ValueKey('inbox-later-$id'),
                          style: text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (missed)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: DurableSaveFeedback(
                          label: todaySharingLabel(l, data.sharingOf(entry)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: border,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                container: true,
                liveRegion: !pending,
                label: l.lay_itemLabel(time, entry.snapshot.pillName, state),
                excludeSemantics: true,
                child: title,
              ),
              ReceiptSwap(
                receipt: hold,
                child: action == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: action,
                      ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: ValueKey('inbox-details-$id'),
                  onPressed: data.busy ? null : openDetails,
                  icon: const Icon(Icons.more_horiz),
                  label: Text(l.t10_details),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ReceiptSwap(receipt: hold, child: card),
    );
  }
}
