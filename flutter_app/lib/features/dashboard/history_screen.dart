import '../../shared/layouts/tab_hand_off.dart';
import '../../shared/layouts/window_size.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/motion/pull_gauge.dart';
import '../../shared/motion/staggered_entrance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/sync/auto_sync_service.dart';
import '../../core/workspace/workspace_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../core/medication/routine_definition.dart';
import '../../shared/scene/dose_bead.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/care_state.dart';
import '../profiles/profile_provider.dart';
import '../analytics/analytics_providers.dart';
import '../analytics/calendar_month_view.dart';
import '../analytics/export/export_bottom_sheet.dart';
import '../analytics/month_panel.dart';
import '../analytics/stats_section.dart';
import '../analytics/trend_widgets.dart';
import '../analytics/trends_view.dart';
import 'history_stock_changes.dart';
import 'history_day_line.dart';
import 'history_day_ribbon.dart';
import 'history_quiet_day.dart';
import 'history_seen_from.dart';
import 'history_provider.dart';
import 'models/history_entry.dart';
import 'care_record_form.dart';
import '../../shared/format/clock.dart';

enum _HistoryView { list, calendar }

enum _Outcome { all, taken, skipped, pending, missed, prn }

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen>
    with TickerProviderStateMixin {
  _HistoryView _view = _HistoryView.list;
  _Outcome _outcome = _Outcome.all;
  DateTime? _day;

  /// The day on screen at the last build, so a change of day knows which
  /// way time moved: +1 toward today, -1 into the past.
  DateTime? _shownDay;
  int _direction = 1;
  bool _allDates = false, _searching = false;

  /// Whether the records of every day read are on show: after "show earlier
  /// records", or, in a wide window, while searching.
  bool _allDays = false;

  /// A wide window's Trends view, instead of the Calendar view.
  bool _trends = false;

  /// Whether the wide calendar has turned to the month of the first day shown.
  bool _monthSynced = false;
  final _search = TextEditingController();

  /// The pull to refresh, which the day line sags under.
  late final PullGauge _pull = PullGauge(vsync: this);
  final _list = GlobalKey(debugLabel: 'history-list');
  final _line = GlobalKey(debugLabel: 'history-line');

  /// Whether the day line has scrolled under the title bar, and the dose
  /// whose record is at the top of the list there.
  final _docked = ValueNotifier(false);
  final _spy = ValueNotifier<String?>(null);

  /// The record rows on screen by dose id, in list order.
  final _rowMarks = <String, BuildContext>{};
  List<String> _rowOrder = const [];

  @override
  void dispose() {
    _search.dispose();
    _pull.dispose();
    _docked.dispose();
    _spy.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    _pull.handle(n, quiet: AppMotion.quiet(context));
    if (n.depth == 0) _dockSoon();
    return false;
  }

  bool _dockQueued = false;

  /// Scroll notifications can arrive mid-layout; positions are read after
  /// the frame, once per frame.
  void _dockSoon() {
    if (_dockQueued) return;
    _dockQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dockQueued = false;
      if (mounted) _updateDock();
    });
  }

  /// Docks the day line once it passes under the title bar, and lights the
  /// dot of the record now at the top of the list.
  void _updateDock() {
    final list = _list.currentContext?.findRenderObject();
    if (list is! RenderBox || !list.attached || !list.hasSize) return;
    final top = list.localToGlobal(Offset.zero).dy;
    final line = _line.currentContext?.findRenderObject();
    final docked =
        _view == _HistoryView.list &&
        !_allDays &&
        (line is RenderBox && line.attached
            ? line.localToGlobal(const Offset(0, HistoryDayLine.lineY)).dy < top
            // The line has left the list's cache: it is far above.
            : _line.currentContext == null && _rowOrder.isNotEmpty);
    _docked.value = docked;
    String? spy;
    if (docked) {
      for (final id in _rowOrder) {
        final row = _rowMarks[id]?.findRenderObject();
        if (row is! RenderBox || !row.attached || !row.hasSize) continue;
        final bottom = row.localToGlobal(Offset(0, row.size.height)).dy;
        if (bottom > top + HistoryDockedLine.height + 6) {
          spy = id;
          break;
        }
      }
    }
    _spy.value = spy;
  }

  void _selectDay(DateTime day) {
    final today = DateUtils.dateOnly(DateTime.now());
    final selected = DateUtils.dateOnly(day.isAfter(today) ? today : day);
    final needed =
        DateTime.utc(today.year, today.month, today.day)
            .difference(
              DateTime.utc(selected.year, selected.month, selected.day),
            )
            .inDays +
        1;
    if (needed > ref.read(historyWindowDaysProvider)) {
      ref.read(historyWindowDaysProvider.notifier).state = needed;
    }
    setState(() {
      final shown = _shownDay;
      if (shown != null && !DateUtils.isSameDay(shown, selected)) {
        _direction = selected.isBefore(shown) ? -1 : 1;
      }
      _day = selected;
      _allDates = false;
      // Choosing a day in a wide window ends a search, whose records are
      // those of every day.
      if (WindowClass.of(context).showsRail) _search.clear();
    });
    if (WindowClass.of(context).showsRail) {
      ref.read(calendarMonthProvider.notifier).select(selected);
    }
  }

  /// A sideways swipe over the records turns to the day before (swiping
  /// right, as if pulling yesterday in from the left) or the day after.
  void _swipeDay(DragEndDetails details) {
    final shown = _shownDay;
    final velocity = details.primaryVelocity ?? 0;
    if (shown == null || _allDays || velocity.abs() < 280) return;
    final today = DateUtils.dateOnly(DateTime.now());
    if (velocity < 0 && !shown.isBefore(today)) return;
    HapticFeedback.selectionClick();
    _selectDay(
      DateTime(shown.year, shown.month, shown.day + (velocity > 0 ? -1 : 1)),
    );
  }

  Future<void> _chooseDay(DateTime current) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final date = await showDatePicker(
      context: context,
      initialDate: current.isAfter(today)
          ? today
          : current.isBefore(DateTime(1900))
          ? DateTime(1900)
          : current,
      firstDate: DateTime(1900),
      lastDate: today,
    );
    if (date != null && mounted) _selectDay(date);
  }

  String _outcomeLabel(AppLocalizations l, _Outcome value) => switch (value) {
    _Outcome.all => l.r09_allRecords,
    _Outcome.prn => l.t08_asNeeded,
    _ => careOutcomeLabel(l, value.name),
  };
  Future<void> _refresh() async {
    final available = ref.read(workspaceContextProvider);
    final captured = available.asData?.value;
    if (available.isLoading || available.hasError || captured == null) return;
    // Local history refresh is a local read, independent of network availability.
    if (!captured.isLocal) {
      try {
        await ref.read(autoSyncServiceProvider).syncNow(captured.ownerUserId);
      } on Object {
        /* Saved history remains available when sharing cannot run. */
      }
    }
    if (!mounted) return;
    final current = ref.read(workspaceContextProvider);
    if (current.isLoading ||
        current.hasError ||
        current.asData == null ||
        !sameCareContext(captured, current.requireValue)) {
      return;
    }
    ref.invalidate(historyLogsProvider);
    ref.invalidate(monthAdherenceProvider);
    ref.invalidate(adherenceStatsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final windowClass = WindowClass.of(context);
    final wide = windowClass.showsRail;
    final workspace = ref.watch(workspaceContextProvider);
    final people = ref.watch(profileListProvider);
    final selected = ref.watch(selectedProfileIdProvider);
    final records = ref.watch(historyLogsProvider);
    final unavailable =
        workspace.hasError || people.hasError || selected.hasError;
    final loading =
        workspace.isLoading ||
        people.isLoading ||
        selected.isLoading ||
        workspace.asData == null ||
        people.asData == null ||
        selected.asData == null;
    // The state the search field lives in: pinned above the page behind the
    // search button on a phone's list and on a medium window, and always in
    // the title bar of an expanded one.
    final searching = switch (windowClass) {
      WindowClass.compact => _searching && _view == _HistoryView.list,
      WindowClass.medium => _searching,
      WindowClass.expanded => false,
    };
    Widget content;
    if (unavailable) {
      content = CareState(
        title: l.t08_unavailable,
        body: l.t08_unavailableBody,
        actionLabel: l.shared_retry,
        action: () {
          ref.invalidate(workspaceContextProvider);
          ref.invalidate(profileListProvider);
          ref.invalidate(selectedProfileIdProvider);
        },
      );
    } else if (loading) {
      content = CareState(title: l.shared_loading, loading: true);
    } else {
      final all = records.hasError || records.isLoading
          ? <HistoryEntry>[]
          : records.asData?.value ?? <HistoryEntry>[];
      final personEntries = all
          .where(
            (e) =>
                selected.requireValue == null ||
                e.personId == selected.requireValue,
          )
          .toList();
      final dates =
          personEntries
              .map((e) => DateTime.tryParse(e.plannedLocalDate ?? ''))
              .whereType<DateTime>()
              .toList()
            ..sort((a, b) => b.compareTo(a));
      final visibleDay =
          _day ?? (dates.firstOrNull ?? DateUtils.dateOnly(DateTime.now()));
      _shownDay = visibleDay;
      if (wide) _showMonthOfFirstDay(visibleDay, loaded: records.hasValue);
      final dayKey = routineDateKey(visibleDay);
      final query = _search.text.trim().toLowerCase();
      // A search in a wide window looks through every day read so far, as the
      // list's "show earlier records" does, since there is no day strip to
      // look along.
      _allDays = _allDates || (wide && query.isNotEmpty);
      final entries =
          personEntries
              .where(
                (e) =>
                    (_allDays ||
                        e.plannedLocalDate == null ||
                        e.plannedLocalDate == dayKey) &&
                    (_outcome == _Outcome.all ||
                        (_outcome == _Outcome.prn
                            ? e.source == 'prn'
                            : e.recordedState == _outcome.name)) &&
                    (query.isEmpty ||
                        e.pillName.toLowerCase().contains(query) ||
                        e.profileName.toLowerCase().contains(query)),
              )
              .toList()
            ..sort(
              (a, b) =>
                  (b.recordedAt ?? b.takenAt ?? b.scheduledAt ?? DateTime(1900))
                      .compareTo(
                        a.recordedAt ??
                            a.takenAt ??
                            a.scheduledAt ??
                            DateTime(1900),
                      ),
            );
      final lineDoses = historyLineDoses(
        context,
        personEntries,
        day: visibleDay,
        now: DateTime.now(),
      );
      _rowOrder = [
        for (final e in entries)
          if (e.plannedLocalDate != null) e.doseLogId,
      ];
      final selectedPerson = people.requireValue
          .where((p) => p.profile.id == selected.requireValue)
          .firstOrNull;
      // Days before this phone knew the people in view are not "quiet": the
      // phone simply wasn't there. Unknown until the first-seen read arrives.
      final seenFrom = historySeenFrom(
        people: selected.requireValue == null
            ? [for (final p in people.requireValue) p.profile.id]
            : [selected.requireValue!],
        firstSeen:
            ref.watch(personFirstSeenProvider).valueOrNull ??
            const <String, DateTime>{},
        entries: personEntries,
      );
      final personFilter = _HistoryFilter<String>(
        menuKey: const ValueKey('history-person-filter'),
        label: selectedPerson?.profile.name ?? l.t08_everyone,
        icon: Icons.people_outline,
        values: [
          PopupMenuItem(value: '', child: Text(l.t08_everyone)),
          for (final person in people.requireValue)
            PopupMenuItem(
              value: person.profile.id,
              child: Text(person.profile.name),
            ),
        ],
        onSelected: (id) async {
          setState(() {
            _day = null;
            _allDates = false;
          });
          try {
            await ref
                .read(selectedProfileIdProvider.notifier)
                .select(id.isEmpty ? null : id);
          } on Object {
            /* The protected provider renders access failures. */
          }
        },
      );
      final planned = lineDoses
          .where((d) => d.bead != DoseBead.asNeeded)
          .length;
      final dayLabel = DateFormat.MMMMEEEEd(
        Localizations.localeOf(context).toString(),
      ).format(visibleDay);

      /// The person and outcome filters with the count of records they leave.
      Widget filters({required bool withOutcome}) => LayoutBuilder(
        builder: (context, bounds) {
          if (!withOutcome) return personFilter;
          final outcomeFilter = _HistoryFilter<_Outcome>(
            menuKey: const ValueKey('history-outcome-filter'),
            label: _outcomeLabel(l, _outcome),
            icon: Icons.article_outlined,
            values: [
              for (final value in _Outcome.values)
                PopupMenuItem(
                  value: value,
                  child: Text(_outcomeLabel(l, value)),
                ),
            ],
            onSelected: (value) => setState(() => _outcome = value),
          );
          final count =
              records.hasError || records.isLoading || records.asData == null
              ? const SizedBox.shrink()
              : Text(
                  l.r09_recordCount(entries.length),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                );
          if (bounds.maxWidth < 350 ||
              MediaQuery.textScalerOf(context).scale(16) > 21) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                personFilter,
                const SizedBox(height: 8),
                outcomeFilter,
                const SizedBox(height: 8),
                count,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                children: [
                  Expanded(child: personFilter),
                  const SizedBox(width: 8),
                  Expanded(child: outcomeFilter),
                ],
              ),
              const SizedBox(height: 6),
              count,
            ],
          );
        },
      );

      /// The records of the day on show (or of every day read, when
      /// searching or after "show earlier records"), with the stock changes
      /// of the day, and the notes and the button that close the list.
      List<Widget> recordBlock() {
        if (records.hasError) {
          return [
            CareState(
              title: l.history_couldNotLoad,
              body: l.t08_unavailableBody,
              actionLabel: l.shared_retry,
              action: () => ref.invalidate(historyLogsProvider),
            ),
          ];
        }
        if (records.isLoading || records.asData == null) {
          return [CareState(title: l.shared_loading, loading: true)];
        }
        final unfiltered = query.isEmpty && _outcome == _Outcome.all;
        return [
          _daySlide(
            ValueKey(_allDays ? 'history-all' : 'history-$dayKey'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (entries.isEmpty &&
                    personEntries.isNotEmpty &&
                    !_allDays &&
                    unfiltered)
                  HistoryQuietDay(
                    key: ValueKey('history-quiet-$dayKey'),
                    day: visibleDay,
                    earlier: dates
                        .where((d) => d.isBefore(visibleDay))
                        .firstOrNull,
                    later: dates.where((d) => d.isAfter(visibleDay)).lastOrNull,
                    seenFrom: seenFrom,
                    person: selectedPerson?.profile.name,
                    onSelect: _selectDay,
                  )
                else if (entries.isEmpty)
                  CareState(
                    title: personEntries.isEmpty
                        ? l.t10_noRecords
                        : l.r09_noMatchingRecords,
                    body: personEntries.isEmpty ? l.t10_noRecordsBody : null,
                  ),
                ..._rows(entries),
                // Stock changes belong to a day, and to the whole of it: not
                // to a search or an outcome filter.
                if (!_allDays && unfiltered)
                  HistoryStockChanges(day: visibleDay),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const CareSharingSummary(),
          Text(
            l.t10_historyHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextButton(
            onPressed: () {
              ref.read(historyWindowDaysProvider.notifier).state += 30;
              setState(() => _allDates = true);
            },
            child: Text(l.t10_loadMore),
          ),
        ];
      }

      /// The selected day, for a wide window: its date and figures, the day
      /// line, the filters and the records.
      List<Widget> dayPane() {
        final recorded = lineDoses
            .where(
              (d) => d.bead == DoseBead.taken || d.bead == DoseBead.skipped,
            )
            .length;
        final asNeeded = lineDoses
            .where((d) => d.bead == DoseBead.asNeeded)
            .length;
        return [
          _dateHeader(visibleDay),
          if (!_allDays) ...[
            const SizedBox(height: 8),
            TileRow(
              key: const ValueKey('history-day-figures'),
              gap: 8,
              tiles: [
                StatTile(
                  dense: true,
                  value: planned == 0
                      ? '—'
                      : l.th_tileOfTotal(recorded, planned),
                  label: l.th_dayPlannedRecorded,
                ),
                StatTile(
                  dense: true,
                  value: '$asNeeded',
                  label: l.th_dayAsNeededDoses(asNeeded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            HistoryDayLine(
              key: _line,
              day: visibleDay,
              doses: lineDoses,
              direction: _direction,
              pull: _pull.value,
              locator: ref.read(historyLineLocatorProvider),
              onOpen: (id) => context.push('/doses/$id'),
            ),
          ],
          const SizedBox(height: 14),
          filters(withOutcome: true),
          const SizedBox(height: 14),
          ...recordBlock(),
        ];
      }

      /// A phone's page: the day line, the day strip and the records, or the
      /// month calendar with the statistics.
      Widget phoneBody() {
        final docked = ValueListenableBuilder<bool>(
          valueListenable: _docked,
          builder: (context, docked, _) => IgnorePointer(
            child: AnimatedOpacity(
              opacity: docked ? 1 : 0,
              duration: AppMotion.duration(context, milliseconds: 120),
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: ContentFrame(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
                    child: HistoryDockedLine(
                      key: const ValueKey('history-docked-line'),
                      day: visibleDay,
                      doses: lineDoses,
                      highlight: _spy,
                      summary: planned == 0
                          ? l.history_ribbonDayEmpty(dayLabel)
                          : l.history_ribbonDay(
                              dayLabel,
                              lineDoses
                                  .where((d) => d.bead == DoseBead.taken)
                                  .length,
                              planned,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final list = RefreshIndicator(
          onRefresh: _refresh,
          child: ContentColumn(
            builder: (context, gutter) =>
                NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: ListView(
                    key: _list,
                    padding:
                        EdgeInsets.fromLTRB(
                          20,
                          8,
                          20,
                          24 + _navClearance(context),
                        ) +
                        gutter,
                    physics: const AlwaysScrollableScrollPhysics(),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    children: [
                      if (_view == _HistoryView.list) ...[
                        _dateHeader(visibleDay),
                        if (!_allDays)
                          HistoryDayLine(
                            key: _line,
                            day: visibleDay,
                            doses: lineDoses,
                            direction: _direction,
                            pull: _pull.value,
                            locator: ref.read(historyLineLocatorProvider),
                            onOpen: (id) => context.push('/doses/$id'),
                          ),
                        const SizedBox(height: 12),
                        HistoryDayRibbon(
                          days: historyRibbonDays(
                            personEntries,
                            today: DateTime.now(),
                            days: ref.watch(historyWindowDaysProvider),
                            seenFrom: seenFrom,
                          ),
                          person: selectedPerson?.profile.name,
                          selected: _allDays ? null : visibleDay,
                          onSelected: _selectDay,
                        ),
                        const SizedBox(height: 14),
                      ],
                      filters(withOutcome: _view == _HistoryView.list),
                      const SizedBox(height: 14),
                      if (_view == _HistoryView.calendar) ...[
                        const CalendarMonthView(),
                        const SizedBox(height: 16),
                        const StatsSection(),
                      ] else
                        ...recordBlock(),
                    ],
                  ),
                ),
          ),
        );
        return Stack(
          children: [
            Positioned.fill(child: list),
            if (_view == _HistoryView.list && !_allDays)
              Positioned(top: 0, left: 0, right: 0, child: docked),
          ],
        );
      }

      Widget page;
      if (wide && _trends) {
        page = _trendsBody(windowClass);
      } else if (windowClass == WindowClass.expanded) {
        page = _expandedCalendar(visibleDay, dayPane());
      } else if (windowClass == WindowClass.medium) {
        page = _mediumCalendar(visibleDay, dayPane());
      } else {
        page = phoneBody();
      }
      // The search field is pinned above the page, so it is in view wherever
      // the page is scrolled to (inside the list it sat below the day line and
      // the ribbon, out of sight on a short window or once scrolled). One
      // column in both states, so opening the field neither rebuilds the page
      // nor loses its scroll position.
      content = Column(
        children: [
          if (searching)
            ContentFrame(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: _searchInput(l, pinned: true),
              ),
            )
          else
            const SizedBox.shrink(),
          Expanded(child: page),
        ],
      );
    }
    return Scaffold(
      appBar: _appBar(
        l,
        theme,
        windowClass,
        enabled: !(unavailable || loading),
      ),
      body: SafeArea(top: false, child: content),
    );
  }

  /// Turns the wide calendar to the month of the day first shown, once, when
  /// the records have been read: the day shown is the latest with records,
  /// which need not be in this month.
  void _showMonthOfFirstDay(DateTime day, {required bool loaded}) {
    if (_monthSynced || !loaded) return;
    _monthSynced = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(calendarMonthProvider.notifier).select(day);
    });
  }

  /// The widest the wide layouts grow, so a very large window does not
  /// stretch the calendar and the day apart.
  static const _wideMax = 1240.0;

  /// An expanded window's Calendar view: the month beside the selected day.
  Widget _expandedCalendar(DateTime day, List<Widget> pane) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _wideMax),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: TwoPane(
          startFlex: 2,
          endFlex: 3,
          start: Card(
            clipBehavior: Clip.antiAlias,
            // The month, its key and its totals read as one block from the
            // top of the card; a tall window leaves the card's foot empty
            // rather than opening a gap in the middle of it. A short window
            // (a keyboard open on a tablet) scrolls it.
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _calendar(day),
                  const SizedBox(height: 8),
                  const CalendarLegend(),
                  const SizedBox(height: 24),
                  const MonthSoFar(),
                ],
              ),
            ),
          ),
          end: Card(
            clipBehavior: Clip.antiAlias,
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  physics: const AlwaysScrollableScrollPhysics(),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: pane,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// A medium window's Calendar view: the month, three figures, then the
  /// selected day, in one column.
  Widget _mediumCalendar(DateTime day, List<Widget> pane) {
    final l = AppLocalizations.of(context);
    final stats = ref.watch(adherenceStatsProvider).valueOrNull;
    final trendAsync = ref.watch(trendStatsProvider);
    final trend = trendAsync.valueOrNull;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ContentColumn(
        builder: (context, gutter) => NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24) + gutter,
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _calendar(day),
                      const SizedBox(height: 8),
                      const CalendarLegend(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TileRow(
                key: const ValueKey('history-week-figures'),
                gap: 8,
                tiles: [
                  adherenceTile(
                    context,
                    l.analytics_last7Days,
                    stats?.last7Days,
                    dense: true,
                    titled: true,
                  ),
                  adherenceTile(
                    context,
                    l.analytics_last30Days,
                    stats?.last30Days,
                    dense: true,
                    titled: true,
                  ),
                  if (trend != null)
                    StatTile(
                      dense: true,
                      value: '${trend.prn7Days}',
                      label: l.th_tileAsNeededDoses,
                      note: l.analytics_last7Days,
                    ),
                ],
              ),
              if (trendReadFailed(trendAsync)) ...[
                const SizedBox(height: 12),
                TrendsLoadError(
                  onRetry: () => ref.invalidate(trendStatsProvider),
                ),
              ],
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: pane,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The month calendar of the wide layouts: tapping a day selects it here.
  Widget _calendar(DateTime day) => CalendarMonthView(
    selectedDay: _allDays ? null : day,
    onDaySelected: _selectDay,
    leadingTitle: true,
    cut: cardColor(context),
  );

  /// The Trends view of a wide window.
  Widget _trendsBody(WindowClass windowClass) => RefreshIndicator(
    onRefresh: _refresh,
    child: windowClass == WindowClass.expanded
        ? SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _wideMax),
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: TrendsView(),
                ),
              ),
            ),
          )
        : const ContentListView(
            physics: AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [StatsSection()],
          ),
  );

  /// Typing in the search field of a wide window looks through the records,
  /// which are in the Calendar view.
  void _searchChanged() => setState(() {
    if (_search.text.trim().isNotEmpty) _trends = false;
  });

  /// The search field. [pinned] is the one above the page (with a button that
  /// clears and closes it); the title bar of an expanded window has its own.
  Widget _searchInput(AppLocalizations l, {required bool pinned}) => TextField(
    key: const ValueKey('history-search'),
    controller: _search,
    autofocus: pinned,
    onChanged: (_) => _searchChanged(),
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      hintText: l.r09_searchHistory,
      prefixIcon: const Icon(Icons.search),
      suffixIcon: pinned || _search.text.isNotEmpty
          ? IconButton(
              tooltip: l.r09_clearSearch,
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _search.clear();
                if (pinned) _searching = false;
              }),
            )
          : null,
    ),
  );

  PreferredSizeWidget _appBar(
    AppLocalizations l,
    ThemeData theme,
    WindowClass windowClass, {
    required bool enabled,
  }) {
    final title = Text(
      l.t08_history,
      style: theme.textTheme.headlineLarge?.copyWith(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -.6,
      ),
    );
    final wide = windowClass.showsRail;
    // On a wide window the pages keep a centered column, so the bar's title
    // and buttons sit at the column's edges rather than the pane's: the side
    // gutter plus the page's own 20 dp margin.
    final gutter = wide
        ? contentGutter(
            MediaQuery.sizeOf(context).width - windowClass.railWidth,
            windowClass.isExpanded ? _wideMax : windowClass.contentWidth,
          )
        : 0.0;
    final export = IconButton(
      tooltip: l.history_exportTooltip,
      icon: const Icon(Icons.ios_share),
      onPressed: !enabled
          ? null
          : () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const ExportBottomSheet(),
            ),
    );
    return AppBar(
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleSpacing: 20 + gutter,
      toolbarHeight: windowClass.isExpanded ? 64 : null,
      title: wide
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  title,
                  const SizedBox(width: 16),
                  Semantics(
                    label: l.th_viewLabel,
                    container: true,
                    child: SegmentedButton<bool>(
                      key: const ValueKey('history-view-toggle'),
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: [
                        ButtonSegment(
                          value: false,
                          label: Text(l.th_viewCalendar),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(l.th_viewTrends),
                        ),
                      ],
                      selected: {_trends},
                      onSelectionChanged: !enabled
                          ? null
                          : (value) => setState(() => _trends = value.first),
                    ),
                  ),
                ],
              ),
            )
          : title,
      actions: [
        if (windowClass.isExpanded)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              width: 320,
              child: enabled ? _searchInput(l, pinned: false) : null,
            ),
          )
        else if (windowClass == WindowClass.medium ||
            _view == _HistoryView.list)
          IconButton(
            tooltip: l.r09_searchHistory,
            icon: const Icon(Icons.search),
            onPressed: !enabled
                ? null
                : () => setState(() {
                    // A closed field must not go on filtering unseen.
                    if (_searching) _search.clear();
                    _searching = !_searching;
                  }),
          ),
        if (!wide)
          IconButton(
            tooltip: _view == _HistoryView.list
                ? l.history_calendar
                : l.history_list,
            icon: Icon(
              _view == _HistoryView.list
                  ? Icons.calendar_month_outlined
                  : Icons.list_outlined,
            ),
            onPressed: !enabled
                ? null
                : () => setState(
                    () => _view = _view == _HistoryView.list
                        ? _HistoryView.calendar
                        : _HistoryView.list,
                  ),
          ),
        export,
        // The share glyph sits 12 dp inside its 48 dp button: this puts it on
        // the column's right edge, with the cards below.
        if (wide) SizedBox(width: gutter + 8),
      ],
    );
  }

  Widget _dateHeader(DateTime date) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toString();
    final today = DateUtils.dateOnly(DateTime.now());
    final title = InkWell(
      onTap: () => _chooseDay(date),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _allDays
                  ? l.r09_recentDays
                  : DateFormat.EEEE(locale).format(date),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              _allDays
                  ? '${DateFormat.yMMMd(locale).format(DateTime(today.year, today.month, today.day - (ref.watch(historyWindowDaysProvider) - 1)))} – ${DateFormat.yMMMd(locale).format(today)}'
                  : DateFormat.yMMMMd(locale).format(date),
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: 23,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
    final navigation = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: l.r09_previousDay,
          onPressed: () =>
              _selectDay(DateTime(date.year, date.month, date.day - 1)),
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: l.r09_nextDay,
          onPressed: date.isBefore(today)
              ? () => _selectDay(DateTime(date.year, date.month, date.day + 1))
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        if (bounds.maxWidth < 330 ||
            MediaQuery.textScalerOf(context).scale(16) > 22) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: navigation,
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            navigation,
          ],
        );
      },
    );
  }

  /// A day's records slide in from the side time moved toward (the past
  /// from the left, like the ribbon), while the day they replace slides out
  /// the other way.
  Widget _daySlide(Key key, Widget child) {
    final direction = _direction;
    final day = KeyedSubtree(key: key, child: child);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: _allDays ? null : _swipeDay,
      child: AppMotion.quiet(context)
          ? day
          : AnimatedSize(
              duration: const Duration(milliseconds: 320),
              curve: AppMotion.curve,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                reverseDuration: const Duration(milliseconds: 220),
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topCenter,
                  children: [...previous, ?current],
                ),
                transitionBuilder: (child, animation) {
                  final incoming = child.key == key;
                  return AnimatedBuilder(
                    animation: animation,
                    child: child,
                    builder: (context, child) {
                      final t = animation.value;
                      final travel = incoming
                          ? Curves.easeOutCubic.transform(t)
                          : t;
                      return IgnorePointer(
                        ignoring: !incoming,
                        child: ExcludeSemantics(
                          excluding: !incoming,
                          child: FractionalTranslation(
                            translation: Offset(
                              (incoming ? direction : -direction) *
                                  (1 - travel) *
                                  .12,
                              0,
                            ),
                            // Shared axis: the old day clears before the new
                            // one shows, so the two never double-expose.
                            child: Opacity(
                              opacity: incoming
                                  ? const Interval(
                                      .35,
                                      1,
                                      curve: Curves.easeOut,
                                    ).transform(t)
                                  : const Interval(
                                      .45,
                                      1,
                                      curve: Curves.easeIn,
                                    ).transform(t),
                              child: child,
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
                child: day,
              ),
            ),
    );
  }

  /// Room so the bottom navigation never covers the last lines at any scale.
  double _navClearance(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(40);

  Widget _group(int index, Object key, List<Widget> children) =>
      StaggeredEntrance(
        key: ValueKey(key),
        index: index,
        identity: 'history-${_allDays ? 'all' : 'day'}',
        child: AnimatedSize(
          duration: AppMotion.standard,
          curve: AppMotion.curve,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      );

  List<Widget> _rows(List<HistoryEntry> entries) {
    final l = AppLocalizations.of(context), text = Theme.of(context).textTheme;
    final dated = entries.where((e) => e.plannedLocalDate != null).toList();
    final unknown = entries.where((e) => e.plannedLocalDate == null).toList();
    final locale = Localizations.localeOf(context).toString();
    Widget heading(String label) => Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
    return [
      if (dated.isNotEmpty) heading(l.r09_latestEntry),
      for (var i = 0; i < dated.length; i++) ...[
        if (i == 1 && !_allDays) heading(l.r09_earlierDay),
        _group(i, dated[i].doseLogId, [
          if (_allDays)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                DateFormat.yMMMMEEEEd(
                  locale,
                ).format(DateTime.parse(dated[i].plannedLocalDate!)),
                style: text.labelMedium,
              ),
            ),
          _RowMark(
            id: dated[i].doseLogId,
            rows: _rowMarks,
            child: _HistoryRow(entry: dated[i], latest: i == 0),
          ),
        ]),
      ],
      if (unknown.isNotEmpty) heading(l.t10_unknownDate),
      for (final entry in unknown) _HistoryRow(entry: entry),
    ];
  }
}

/// Puts a record row in [rows] while it is on screen, so the docked day line
/// can tell which record is at the top of the list.
class _RowMark extends StatefulWidget {
  const _RowMark({required this.id, required this.rows, required this.child});
  final String id;
  final Map<String, BuildContext> rows;
  final Widget child;
  @override
  State<_RowMark> createState() => _RowMarkState();
}

class _RowMarkState extends State<_RowMark> {
  @override
  void initState() {
    super.initState();
    widget.rows[widget.id] = context;
  }

  @override
  void didUpdateWidget(_RowMark old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id && old.rows[old.id] == context) {
      old.rows.remove(old.id);
    }
    widget.rows[widget.id] = context;
  }

  @override
  void dispose() {
    if (widget.rows[widget.id] == context) widget.rows.remove(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _HistoryFilter<T> extends StatelessWidget {
  const _HistoryFilter({
    required this.menuKey,
    required this.label,
    required this.icon,
    required this.values,
    required this.onSelected,
  });
  final Key menuKey;
  final String label;
  final IconData icon;
  final List<PopupMenuEntry<T>> values;
  final ValueChanged<T> onSelected;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<T>(
      key: menuKey,
      tooltip: label,
      itemBuilder: (_) => values,
      onSelected: onSelected,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.outline),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 20),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, this.latest = false});
  final HistoryEntry entry;
  final bool latest;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final colors = theme.colorScheme;
    final stacked =
        MediaQuery.textScalerOf(context).scale(16) > 21 ||
        MediaQuery.sizeOf(context).width < 360;
    final planned = entry.source == 'prn'
        ? l.t08_asNeeded
        : entry.plannedLocalTime == null
        ? l.t08_unknownTime
        : clockText(context, entry.plannedLocalTime!);
    final outcomeColor = theme.extension<AppSemanticColors>()!.forState(
      entry.recordedState,
    );
    final recorded =
        entry.recordedState == 'taken' || entry.recordedState == 'skipped';
    // A miss was written by the app: it has an entry time but no actual time
    // and no author to show.
    final missed = entry.recordedState == 'missed';
    final actual = entry.actualTimeKnown
        ? careInstantLabel(context, entry.takenAt)
        : l.t08_unknownTime;
    final avatar = ExcludeSemantics(
      child: CircleAvatar(
        radius: 19,
        backgroundColor: colors.primaryContainer,
        foregroundColor: colors.onPrimaryContainer,
        child: Text(
          entry.profileName.trim().characters.firstOrNull?.toUpperCase() ?? '?',
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
        ),
      ),
    );
    final identity = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stacked) ...[avatar, const SizedBox(width: 10)],
        Expanded(
          child: Text(
            entry.profileName,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (entry.occurrenceId != null)
          const Icon(Icons.chevron_right, size: 22),
      ],
    );
    final facts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        identity,
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              switch (entry.recordedState) {
                'taken' => Icons.check_circle_outline,
                'skipped' => Icons.block,
                'missed' => Icons.error_outline_rounded,
                _ => Icons.radio_button_unchecked,
              },
              size: 23,
              color: AppTheme.readable(outcomeColor, [colors.surface]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                careOutcomeLabel(l, entry.recordedState, late: entry.takenLate),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(entry.pillName, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 6),
        _HistoryFact(label: l.t10_planned, value: planned),
        // A dose nobody recorded yet has no actual time, entry time or author.
        if (recorded) _HistoryFact(label: l.t10_actual, value: actual),
        if (!entry.amount.isUnknown)
          _HistoryFact(
            label: l.t10_recordedAmount,
            value: careAmountLabel(l, entry.amount),
          ),
        if (recorded || missed)
          _HistoryFact(
            label: l.t10_entered,
            value: entry.recordedAt == null
                ? l.t08_unknown
                : careInstantLabel(context, entry.recordedAt),
          ),
        if (recorded) ...[
          _HistoryFact(
            label: l.t10_author,
            value:
                entry.authorName ??
                (entry.authorId == null
                    ? l.t10_unknownAuthor
                    : l.t10_unnamedAuthor),
          ),
        ],
        if (entry.provenance != 'exact')
          Text(l.t10_legacy, style: theme.textTheme.bodySmall),
        if (entry.auditEvents.length > 1)
          Text(
            l.t10_recordHistory,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.primary),
          ),
        if (entry.occurrenceId != null)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              l.t10_details,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.primary,
              ),
            ),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: latest ? colors.onSurface : colors.outline,
            width: latest ? 1.2 : .8,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('history-record-${entry.doseLogId}'),
          onTap: entry.occurrenceId == null
              ? null
              : () => context.push('/doses/${entry.occurrenceId}'),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (latest) Container(width: 6, color: colors.primaryContainer),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: stacked
                        ? facts
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              avatar,
                              const SizedBox(width: 12),
                              Expanded(child: facts),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryFact extends StatelessWidget {
  const _HistoryFact({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Wrap(
      spacing: 5,
      children: [
        Text(
          '$label:',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}
