import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:timezone/timezone.dart' as tz;
import '../../core/db/database.dart' show MedicationOccurrence, Profile;
import '../../shared/format/clock.dart';
import '../../core/medication/care_day.dart';
import '../../core/medication/care_provider.dart';
import '../../core/medication/care_recording.dart';
import '../../core/medication/late_dose.dart';
import '../../core/medication/reviewed_stock.dart' show CareStockOutcome;
import '../../core/medication/medication_repository.dart'
    show MedicationCommandBlocked;
import '../../core/utils/app_logger.dart';
import '../../core/medication/reviewed_time_zone.dart';
import '../../core/medication/routine_definition.dart';
import '../../core/storage/appearance_preferences.dart';
import '../../core/storage/as_needed_shortcut_preference.dart';
import '../../core/sync/auto_sync_service.dart';
import '../../core/storage/layout_family_preference.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/workspace/workspace_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/motion/ambient_motion.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/motion/pressable.dart';
import 'today_layout/layout_reveal.dart';
import 'today_layout/entry_identity.dart';
import 'today_layout/sky_flight.dart';
import '../../shared/layouts/tab_hand_off.dart';
import '../../shared/layouts/window_size.dart';
import '../../shared/motion/pull_gauge.dart';
import '../../shared/scene/ambient_sky.dart';
import '../../shared/scene/horizon_model.dart';
import '../../shared/scene/horizon_scene.dart';
import '../../shared/scene/scene_clock.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/care_state.dart';
import '../../shared/widgets/care_person_selector.dart';
import '../../shared/widgets/durable_save_feedback.dart';
import '../profiles/profile_provider.dart';
import 'day_overview.dart';
import 'dose_card_strip.dart';
import 'selected_date_provider.dart';
import 'care_record_form.dart';
import 'selected_doses_review.dart';
import 'as_needed/as_needed_option.dart';
import 'as_needed/as_needed_section.dart';
import 'as_needed/as_needed_shortcut.dart';
import 'today_layout/today_layout.dart';
import '../updates/presentation/update_available_card.dart';
import 'today_layout/low_stock_notice.dart';
import 'today_side/stock_overview.dart';
import 'today_side/today_side_column.dart';
import 'today_side/week_strip.dart';
import 'dose_detail_screen.dart' show DoseDetailPanel;
import 'care_record_launch.dart';
import '../../core/storage/low_stock_dismissal_preference.dart';
import 'today_layout/today_layouts.dart';
import '../pills/presentation/medication_identity.dart';
import '../../shared/widgets/clock_text.dart';

/// A tap on a sky mark asks the deck to focus that exact occurrence; [seq]
/// makes a repeated tap on the same mark a new request.
final _skyFocusProvider = StateProvider.autoDispose<({String id, int seq})?>(
  (ref) => null,
);

/// Set to the settling receipt's id when the last dose of the day lands, for
/// the sky's one-time settled sweep.
final _skySweepProvider = StateProvider.autoDispose<String?>((ref) => null);

/// Days (local dates) whose sweep has played in this run: once per day.
final _sweptDaysProvider = StateProvider<Set<String>>((ref) => const {});

/// Occurrence whose take the deck just durably recorded (null after undo), so
/// its sky mark twinkles once.
final _skyCelebrateProvider = StateProvider.autoDispose<String?>((ref) => null);

/// Occurrence the deck currently focuses, so the sky's focus ring follows the
/// card. The sky uses it only when it names one of its own marks.
final _skyFocusedProvider = StateProvider.autoDispose<String?>((ref) => null);

/// The dose whose details fill the right pane of an expanded Today, or null
/// when the pane shows the side column. Phones and medium windows never set
/// it: they push the full-page route instead.
final todayDetailsProvider = StateProvider.autoDispose<String?>((ref) => null);

class FocusTodayScreen extends ConsumerStatefulWidget {
  const FocusTodayScreen({super.key});
  @override
  ConsumerState<FocusTodayScreen> createState() => _FocusTodayScreenState();
}

class _FocusTodayScreenState extends ConsumerState<FocusTodayScreen>
    with TickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();

  /// The scrolling panes of a medium or expanded window: the layout's (the
  /// only one on a medium window) and, on an expanded one, the side column's.
  final ScrollController _mainScroll = ScrollController();
  final ScrollController _sideScroll = ScrollController();

  /// A sky card never collapses: the header's collapse, held at rest.
  final ValueNotifier<double> _still = ValueNotifier(0);

  /// Locates the As needed section inside the list, for the shortcut pill.
  final GlobalKey _asNeededKey = GlobalKey();

  /// True while the As needed section exists and is below the visible area.
  final ValueNotifier<bool> _asNeededBelow = ValueNotifier(false);
  bool _hasAsNeeded = false;

  /// True while a pull to refresh is syncing; the sync thread shows it.
  final ValueNotifier<bool> _refreshing = ValueNotifier(false);

  /// Scene height measured by the header, shared with the app bar strip.
  final ValueNotifier<double?> _skyHeight = ValueNotifier(null);

  /// How far the header has scrolled away, 0..1 ([skyCollapseAt]): the
  /// sky's bodies, ground, path and marks fade out with it.
  final ValueNotifier<double> _collapse = ValueNotifier(0);
  double _topInset = 0;

  /// How far the sky is pulled down, 0 at rest and 1 at the refresh
  /// threshold: the sun sinks and the horizon warms while the finger holds,
  /// then both ease back. Feedback only; sync status stays in words.
  late final PullGauge _pullGauge = PullGauge(vsync: this);
  ValueNotifier<double> get _pull => _pullGauge.value;

  bool _onScrollNotification(ScrollNotification n) =>
      _pullGauge.handle(n, quiet: AppMotion.quiet(context));

  /// Pull to refresh: sharing workspaces sync (flush before pull, inside the
  /// sync service), then the day is read again. A local workspace just reads.
  Future<void> _refresh() async {
    final captured = ref.read(workspaceContextProvider).asData?.value;
    if (captured == null) return;
    if (!captured.isLocal) {
      _refreshing.value = true;
      try {
        await ref.read(autoSyncServiceProvider).syncNow(captured.ownerUserId);
      } on Object {
        /* The saved day stays available when sharing cannot run. */
      } finally {
        _refreshing.value = false;
      }
    }
    if (!mounted) return;
    ref.invalidate(careDayProvider);
  }

  void _updateCollapse() {
    final sky = _skyHeight.value;
    if (sky == null || !_scroll.hasClients || _scroll.positions.length != 1) {
      _collapse.value = 0;
      return;
    }
    // The header box is what the sky's scene was measured against.
    final header = math.max(40.0, sky * .8 - 6 - _topInset);
    _collapse.value = (_scroll.offset / (header * skyCollapseAt)).clamp(
      0.0,
      1.0,
    );
  }

  /// Measures after the next layout: a scroll listener runs before the slivers
  /// move, so reading positions right away would be one step behind.
  void _scheduleAsNeededUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateAsNeededBelow();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _updateAsNeededBelow() {
    var below = false;
    if (_hasAsNeeded && _scroll.hasClients && _scroll.positions.length == 1) {
      final box = _asNeededKey.currentContext?.findRenderObject();
      if (box is RenderBox && box.attached) {
        final viewport = RenderAbstractViewport.maybeOf(box);
        if (viewport != null) {
          // The section's top edge within the viewport (unclamped, unlike
          // getOffsetToReveal, which stops at the scroll extent).
          final top = box
              .localToGlobal(Offset.zero, ancestor: viewport as RenderObject)
              .dy;
          // Hide as soon as the heading peeks in, so the pill never covers it.
          below = top >= _scroll.position.viewportDimension;
        }
      } else {
        // Not built yet: it lies beyond the list's cache, further down.
        below = true;
      }
    }
    if (_asNeededBelow.value != below) _asNeededBelow.value = below;
  }

  Future<void> _jumpToAsNeeded() async {
    final duration = AppMotion.quiet(context)
        ? Duration.zero
        : AppMotion.emphasis;
    if (_asNeededKey.currentContext == null) {
      if (!_scroll.hasClients) return;
      await _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: duration,
        curve: AppMotion.curve,
      );
      if (!mounted) return;
    }
    final target = _asNeededKey.currentContext;
    if (target == null || !target.mounted) return;
    await Scrollable.ensureVisible(
      target,
      duration: duration,
      curve: AppMotion.curve,
    );
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateCollapse);
    _scroll.addListener(_scheduleAsNeededUpdate);
    _skyHeight.addListener(_updateCollapse);
  }

  /// The halo breath: the only loop-like motion, and only while the user is
  /// touching the screen and for 12 s after (never under tests or quiet).
  late final AnimationController _breath =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..addStatusListener((status) {
          if (!mounted) return;
          if (status == AnimationStatus.completed) {
            _breath.reverse();
          } else if (status == AnimationStatus.dismissed &&
              AmbientMotion.of(context) &&
              --_breathsLeft > 0) {
            _breath.forward();
          }
        });

  /// Each touch allows three more 4 s breaths, i.e. 12 s after the last one.
  int _breathsLeft = 0;

  /// One drift for both copies of the sky (app bar strip and header), so
  /// their clouds stay in step. [AmbientSkyDriver] decides when it runs.
  final AmbientDrift _ambient = AmbientDrift();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A dialog or sheet over Today (or a hidden tab) rests the breath too.
    if (!AmbientMotion.of(context) && _breath.isAnimating) {
      _breathsLeft = 0;
      _breath.value = 0;
    }
  }

  void _touched(PointerEvent _) {
    _ambient.wake();
    if (!AmbientMotion.of(context)) return;
    _breathsLeft = 3;
    if (!_breath.isAnimating) _breath.forward();
  }

  @override
  void dispose() {
    _refreshing.dispose();
    _breath.dispose();
    _pullGauge.dispose();
    _ambient.dispose();
    _scroll.dispose();
    _mainScroll.dispose();
    _sideScroll.dispose();
    _still.dispose();
    _asNeededBelow.dispose();
    _skyHeight.dispose();
    _collapse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final workspace = ref.watch(workspaceContextProvider);
    final profiles = ref.watch(profileListProvider);
    final selected = ref.watch(selectedProfileIdProvider);
    final date = ref.watch(selectedDateProvider);
    final detailsId = ref.watch(todayDetailsProvider);
    final locale = Localizations.localeOf(context).toString();
    final day = routineDateKey(date);
    final window = WindowClass.of(context);
    // Medium and expanded windows have a rail and room for more than the
    // phone's one scrolling header: a sky card above the page instead.
    final wide = window.showsRail;
    // The sky starts at the top of the screen, this far above the list.
    final topInset = MediaQuery.paddingOf(context).top + _todayToolbarHeight;
    _topInset = topInset;
    // A new layout always opens on the full header, never half-collapsed at
    // the previous layout's offset.
    ref.listen(layoutFamilyProvider, (previous, next) {
      if (previous == null ||
          effectiveLayoutFamily(previous) == effectiveLayoutFamily(next)) {
        return;
      }
      for (final controller in [_scroll, _mainScroll]) {
        if (controller.hasClients && controller.positions.length == 1) {
          controller.jumpTo(0);
        }
      }
    });
    Widget body;
    Widget? skyStrip;
    var skyOn = false;
    var shortcutOn = false;
    if (workspace.hasError || profiles.hasError || selected.hasError) {
      body = CareState(
        title: l.t08_unavailable,
        body: l.t08_unavailableBody,
        actionLabel: l.shared_retry,
        action: () {
          ref.invalidate(workspaceContextProvider);
          ref.invalidate(profileListProvider);
          ref.invalidate(selectedProfileIdProvider);
        },
      );
    } else if (workspace.isLoading ||
        profiles.isLoading ||
        selected.isLoading) {
      body = CareState(title: l.shared_loading, loading: true);
    } else {
      skyOn = true;
      final captured = workspace.requireValue;
      final identity =
          '${captured.workspaceId}/${captured.accessEpoch}/${captured.sessionGeneration}/${captured.networkEpoch}/$day/${selected.value}';
      final people = profiles.requireValue.map((p) => p.profile).toList();
      final theme = Theme.of(context);
      final titleStyle = theme.textTheme.headlineLarge?.copyWith(
        fontSize: 40,
        height: 1.1,
        fontWeight: FontWeight.w700,
        letterSpacing: -.8,
      );
      final dateStyle = theme.textTheme.bodyLarge?.copyWith(
        fontSize: 18,
        color: theme.colorScheme.onSurfaceVariant,
      );
      final dateText = DateFormat.MMMMEEEEd(locale).format(date);
      final scaler = MediaQuery.textScalerOf(context);
      final request = CareDayRequest(localDate: day, personId: selected.value);
      _closeDetailsWhenStale(identity, expanded: window.isExpanded);
      if (wide) {
        _hasAsNeeded = false;
        body = _wideBody(
          l: l,
          identity: identity,
          request: request,
          date: date,
          day: day,
          dateText: dateText,
          titleStyle: titleStyle,
          dateStyle: dateStyle,
          people: people,
          selectedId: selected.value,
          detailsId: window.isExpanded ? detailsId : null,
        );
      } else {
        final words = _HeaderWords(
          title: l.t08_today,
          titleStyle: titleStyle,
          date: dateText,
          dateStyle: dateStyle,
          topInset: topInset,
          scaler: scaler,
          direction: Directionality.of(context),
          // The week rides in the header: room is kept for it from the first
          // frame, so the sun never jumps when the dots arrive.
          strip: Size(WeekStrip.widthFor(scaler), WeekStrip.heightFor(scaler)),
        );
        _hasAsNeeded =
            ref
                .watch(asNeededOptionsProvider(request))
                .asData
                ?.value
                .isNotEmpty ??
            false;
        _scheduleAsNeededUpdate();
        shortcutOn = _hasAsNeeded && ref.watch(asNeededShortcutProvider);
        skyStrip = _TodaySky(
          key: ValueKey('sky-strip/$identity'),
          request: request,
          date: date,
          scroll: _scroll,
          breath: _breath,
          ambient: _ambient,
          height: _skyHeight,
          collapse: _collapse,
          // The strip paints the same sky over the header; it must follow the
          // pull too, or its sun stays put while the header's sun drops.
          pull: _pull,
          words: words,
          strip: true,
        );
        body = ContentColumn(
          builder: (context, gutter) => _LiftedForShortcut(
            lifted: shortcutOn ? _asNeededBelow : null,
            child: NotificationListener<ScrollMetricsNotification>(
              // Content above the section grew or shrank: it may have moved.
              onNotification: (_) {
                _scheduleAsNeededUpdate();
                return false;
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  edgeOffset: topInset,
                  child: ListView(
                    key: PageStorageKey('today/$identity'),
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    // Room so the bottom navigation never sits on the last action
                    // (Dose details) at any text scale.
                    padding:
                        EdgeInsets.fromLTRB(20, 0, 20, 20 + scaler.scale(40)) +
                        gutter,
                    children: [
                      // The sky is drawn behind the header and adds no height: the
                      // date line leaves room under its text where the marks sit.
                      Stack(
                        fit: StackFit.passthrough,
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            top: -topInset,
                            // The sky spans the whole pane, past the column's
                            // own margins and the page padding.
                            left: -(20 + gutter.left),
                            right: -(20 + gutter.right),
                            bottom: 0,
                            child: _TodaySky(
                              key: ValueKey('sky/$identity'),
                              request: request,
                              date: date,
                              scroll: _scroll,
                              breath: _breath,
                              ambient: _ambient,
                              height: _skyHeight,
                              collapse: _collapse,
                              pull: _pull,
                              words: words,
                            ),
                          ),
                          // Words over the sky must not swallow taps on raised marks.
                          IgnorePointer(
                            child: _PhoneHeaderWords(
                              words: words,
                              request: request,
                              titleStyle: titleStyle,
                              dateStyle: dateStyle,
                              title: l.t08_today,
                              date: dateText,
                            ),
                          ),
                        ],
                      ),
                      ..._dayChildren(
                        l: l,
                        identity: identity,
                        request: request,
                        day: day,
                        people: people,
                        selectedId: selected.value,
                      ),
                      KeyedSubtree(
                        key: _asNeededKey,
                        child: AsNeededSection(
                          key: ValueKey('as-needed/$identity'),
                          request: request,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    if (!skyOn || wide) _hasAsNeeded = false;
    final showShortcut = skyStrip != null && shortcutOn;
    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: showShortcut
          ? AsNeededShortcut(
              visible: _asNeededBelow,
              onPressed: _jumpToAsNeeded,
            )
          : null,
      // The sky card carries the title and the date controls on a wide
      // window; the rail carries the brand and Settings.
      appBar: wide
          ? null
          : AppBar(
              toolbarHeight: _todayToolbarHeight,
              // The top of the same screen-fixed sky, so content never scrolls
              // under the brand and the seam with the header cannot show.
              flexibleSpace: skyStrip,
              title: Text(
                'Simpastil',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              titleSpacing: 20,
              actions: [
                IconButton(
                  tooltip: l.t08_date,
                  icon: const Icon(Icons.calendar_today_outlined, size: 22),
                  onPressed: () => _chooseDate(context, ref, date),
                ),
                IconButton(
                  tooltip: l.nav_settings,
                  onPressed: () => context.push('/settings'),
                  icon: const Icon(Icons.settings_outlined, size: 26),
                ),
              ],
            ),
      body: AmbientSkyDriver(
        drift: _ambient,
        // High contrast draws a plain sky: nothing to move.
        enabled:
            skyOn &&
            !ref.watch(highContrastEnabledProvider) &&
            !MediaQuery.highContrastOf(context),
        collapse: wide ? _still : _collapse,
        child: Listener(
          onPointerDown: _touched,
          onPointerMove: _touched,
          child: SafeArea(top: false, child: body),
        ),
      ),
    );
  }

  /// The identity the open details panel was opened under.
  String? _detailsIdentity;

  /// Closes the details panel when the day, person or workspace changes under
  /// it, and when the window can no longer hold a side panel.
  void _closeDetailsWhenStale(String identity, {required bool expanded}) {
    final previous = _detailsIdentity;
    _detailsIdentity = identity;
    final stale = previous != null && previous != identity;
    if (ref.read(todayDetailsProvider) == null || (expanded && !stale)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(todayDetailsProvider.notifier).state = null;
    });
  }

  /// The controls above the day's layout, shared by every window class.
  List<Widget> _dayChildren({
    required AppLocalizations l,
    required String identity,
    required CareDayRequest request,
    required String day,
    required List<Profile> people,
    required String? selectedId,
  }) => [
    const UpdateAvailableCard(margin: EdgeInsets.only(bottom: 8)),
    if (day != routineDateKey(DateTime.now()))
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: () =>
              ref.read(selectedDateProvider.notifier).select(DateTime.now()),
          child: Text(l.t08_returnToday),
        ),
      ),
    CarePersonSelector(
      focusDeckPresentation: true,
      people: people,
      selectedId: selectedId,
      onChanged: (id) async {
        try {
          await ref.read(selectedProfileIdProvider.notifier).select(id);
        } on Object {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(l.t08_unavailable)));
          }
        }
      },
    ),
    const SizedBox(height: 4),
    CareSharingSummary(refreshing: _refreshing),
    _FocusDay(key: ValueKey(identity), request: request),
  ];

  /// Today on a medium or expanded window: the sky card across the top, then
  /// the chosen layout with As needed, Stock and This week around it.
  ///
  /// Expanded windows split into two panes that scroll on their own: the
  /// layout on the left, the side column (or Dose details) on the right.
  /// Medium windows keep one column.
  Widget _wideBody({
    required AppLocalizations l,
    required String identity,
    required CareDayRequest request,
    required DateTime date,
    required String day,
    required String dateText,
    required TextStyle? titleStyle,
    required TextStyle? dateStyle,
    required List<Profile> people,
    required String? selectedId,
    required String? detailsId,
  }) {
    final expanded = WindowClass.of(context).isExpanded;
    final scaler = MediaQuery.textScalerOf(context);
    final words = _CardWords(
      title: l.t08_today,
      titleStyle: titleStyle,
      date: dateText,
      dateStyle: dateStyle,
      scaler: scaler,
      direction: Directionality.of(context),
    );
    final top = MediaQuery.paddingOf(context).top + 16;
    final bottom = 24 + scaler.scale(16);
    final dayChildren = _dayChildren(
      l: l,
      identity: identity,
      request: request,
      day: day,
      people: people,
      selectedId: selectedId,
    );
    final today = day == routineDateKey(DateTime.now());
    final card = LayoutBuilder(
      builder: (context, box) => _SkyCard(
        height: words.heightFor(box.maxWidth),
        sky: _TodaySky(
          key: ValueKey('sky-card/$identity'),
          request: request,
          date: date,
          scroll: _mainScroll,
          breath: _breath,
          ambient: _ambient,
          height: _skyHeight,
          collapse: _still,
          pull: _pull,
          cardHeight: words.heightFor(box.maxWidth),
          zones: words.zonesIn,
        ),
        title: l.t08_today,
        titleStyle: titleStyle,
        date: dateText,
        dateStyle: dateStyle,
        words: words,
        previous: () => ref.read(selectedDateProvider.notifier).previousDay(),
        pick: () => _chooseDate(context, ref, date),
        next: today
            ? null
            : () => ref.read(selectedDateProvider.notifier).nextDay(),
      ),
    );
    return ContentColumn(
      maxWidth: expanded ? _expandedPageWidth : _mediumPageWidth,
      builder: (context, gutter) {
        final side = 20 + gutter.left;
        Widget pane(
          List<Widget> children, {
          required ScrollController controller,
          required EdgeInsets padding,
          required Object storageKey,
          bool pullsSky = false,
        }) {
          Widget scroll = RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              key: PageStorageKey('$storageKey/$identity'),
              controller: controller,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: padding,
              children: children,
            ),
          );
          if (pullsSky) {
            scroll = NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: scroll,
            );
          }
          return scroll;
        }

        final Widget panes;
        if (expanded) {
          final detailsOpen = detailsId != null;
          panes = TwoPane(
            gap: 0,
            startFlex: detailsOpen ? 40 : 47,
            endFlex: detailsOpen ? 60 : 53,
            start: pane(
              [
                ...dayChildren,
                // The side column's As needed card gives way to the details
                // panel; the cards stay one scroll away on the left.
                if (detailsOpen) ...[
                  const SizedBox(height: 16),
                  AsNeededSection(
                    key: ValueKey('as-needed/$identity'),
                    request: request,
                    card: true,
                    maxColumns: 3,
                  ),
                ],
              ],
              controller: _mainScroll,
              padding: EdgeInsets.fromLTRB(side, 4, 8, bottom),
              storageKey: 'today-main',
              pullsSky: true,
            ),
            end: detailsOpen
                ? Padding(
                    padding: EdgeInsets.fromLTRB(8, 4, side, bottom),
                    child: DoseDetailPanel(
                      occurrenceId: detailsId,
                      onClose: () =>
                          ref.read(todayDetailsProvider.notifier).state = null,
                    ),
                  )
                : pane(
                    [TodaySideColumn(request: request)],
                    controller: _sideScroll,
                    padding: EdgeInsets.fromLTRB(8, 4, side, bottom),
                    storageKey: 'today-side',
                  ),
          );
        } else {
          panes = pane(
            [
              ...dayChildren,
              const SizedBox(height: 16),
              TodaySideColumn(request: request, showComingUp: true),
            ],
            controller: _mainScroll,
            padding: EdgeInsets.fromLTRB(side, 4, side, bottom),
            storageKey: 'today-main',
            pullsSky: true,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(side, top, side, 12),
              child: card,
            ),
            Expanded(child: panes),
          ],
        );
      },
    );
  }
}

/// How wide the Today page grows on an expanded window, margins included.
const double _expandedPageWidth = 1280;

/// How wide it grows on a medium window, margins included.
const double _mediumPageWidth = 680;

/// The sky card at the top of Today on a medium or expanded window: the sky
/// with the title and date on it and the day controls at its far end.
class _SkyCard extends StatelessWidget {
  const _SkyCard({
    required this.height,
    required this.sky,
    required this.title,
    required this.titleStyle,
    required this.date,
    required this.dateStyle,
    required this.words,
    required this.previous,
    required this.pick,
    required this.next,
  });

  final double height;
  final Widget sky;
  final String title, date;
  final TextStyle? titleStyle, dateStyle;
  final _CardWords words;
  final VoidCallback previous, pick;

  /// Null on today: there is no later day to go to.
  final VoidCallback? next;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    Widget button(IconData icon, String tooltip, VoidCallback? onPressed) =>
        IconButton(
          key: ValueKey('today-card-$tooltip'),
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 22),
          style: IconButton.styleFrom(
            fixedSize: Size.square(_CardWords.controls.height),
            backgroundColor: colors.surface.withValues(alpha: .55),
            foregroundColor: colors.onSurface,
            disabledBackgroundColor: colors.surface.withValues(alpha: .3),
            disabledForegroundColor: colors.onSurface.withValues(alpha: .38),
          ),
        );
    return SizedBox(
      key: const ValueKey('today-sky-card'),
      height: height,
      child: Stack(
        children: [
          Positioned.fill(child: sky),
          // Words over the sky must not swallow taps on raised marks.
          PositionedDirectional(
            start: _CardWords.padding,
            end: _CardWords.textEndInset,
            top: _CardWords.top,
            child: IgnorePointer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: titleStyle),
                  Text(date, style: dateStyle),
                ],
              ),
            ),
          ),
          PositionedDirectional(
            end: _CardWords.controlsInset,
            top: _CardWords.controlsInset,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                button(Icons.chevron_left, l.tt_previousDay, previous),
                const SizedBox(width: _CardWords.controlsGap),
                button(Icons.calendar_today_outlined, l.t08_date, pick),
                const SizedBox(width: _CardWords.controlsGap),
                button(Icons.chevron_right, l.tt_nextDay, next),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The phone header's words, with the week strip beside the title when it
/// fits and under the date when it does not.
class _PhoneHeaderWords extends StatelessWidget {
  const _PhoneHeaderWords({
    required this.words,
    required this.request,
    required this.titleStyle,
    required this.dateStyle,
    required this.title,
    required this.date,
  });

  final _HeaderWords words;
  final CareDayRequest request;
  final TextStyle? titleStyle, dateStyle;
  final String title, date;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final inline = words.stripInline(box.maxWidth);
      final strip = WeekStrip(request: request);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (inline)
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: Text(title, style: titleStyle)),
                strip,
              ],
            )
          else
            Text(title, style: titleStyle),
          // Marks rest just below this line; the band grows with the text so
          // words and marks never share a spot.
          if (inline)
            ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: math.max(48.0, words.dateHeight(box.maxWidth) + 9),
              ),
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: Text(date, style: dateStyle),
              ),
            )
          else ...[
            Text(date, style: dateStyle),
            const SizedBox(height: 6),
            Align(alignment: AlignmentDirectional.centerEnd, child: strip),
            const SizedBox(height: 9),
          ],
          const SizedBox(height: 8),
        ],
      );
    },
  );
}

const double _todayToolbarHeight = 48;

/// The corner radius of the sky card on a medium or expanded window.
const double _skyCardRadius = 24;

/// Lifts the page's bottom edge clear of the floating "As needed" pill while
/// the pill is shown, so the pill sits in its own strip instead of covering
/// the last actions (Dose details, Select doses) at the fold.
///
/// The strip appears only while the section is below the visible area and the
/// list measures against the viewport it has, so showing it can never make
/// the section look visible and hide the pill again.
class _LiftedForShortcut extends StatelessWidget {
  const _LiftedForShortcut({required this.lifted, required this.child});

  /// True while the pill is shown; null when there is no pill at all.
  final ValueListenable<bool>? lifted;
  final Widget child;

  /// The pill's minimum height plus the margin it floats at and some air.
  static const _room = 48.0 + 16 + 8;

  @override
  Widget build(BuildContext context) {
    final source = lifted;
    if (source == null) return child;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    final duration = AppMotion.quiet(context)
        ? Duration.zero
        : AppMotion.standard;
    return ValueListenableBuilder<bool>(
      valueListenable: source,
      child: child,
      builder: (context, shown, child) => AnimatedPadding(
        duration: duration,
        curve: AppMotion.curve,
        padding: EdgeInsets.only(bottom: shown ? _room * scale : 0),
        child: child,
      ),
    );
  }
}

/// The share of the header's height scrolled away at which the sky's
/// bodies, ground, path and marks have fully faded.
@visibleForTesting
const double skyCollapseAt = .6;

/// The title and date words of the Today header, so the sky can keep its
/// bodies and marks clear of them at the live text scale.
class _HeaderWords {
  const _HeaderWords({
    required this.title,
    required this.titleStyle,
    required this.date,
    required this.dateStyle,
    required this.topInset,
    required this.scaler,
    required this.direction,
    this.strip = Size.zero,
  });

  /// The size of the week strip the header carries, or zero when it has none
  /// (every window but the phone's).
  final Size strip;

  final String title;
  final TextStyle? titleStyle;
  final String date;
  final TextStyle? dateStyle;
  final double topInset;
  final TextScaler scaler;
  final TextDirection direction;

  static const side = 20.0;

  Size _measure(String text, TextStyle? style, double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: math.max(40.0, width));
    final size = painter.size;
    painter.dispose();
    return size;
  }

  /// The date line's own height for a content area [width] wide.
  double dateHeight(double width) => _measure(date, dateStyle, width).height;

  /// Whether the week strip sits in the title's row (it fits beside the word)
  /// instead of in a row of its own under the date.
  bool stripInline(double width) =>
      strip.width > 0 &&
      _measure(title, titleStyle, width).width + 12 + strip.width <= width;

  /// Where the words sit in a sky scene [scene] big: the scene spans the
  /// page's side padding and starts at the top of the screen.
  List<Rect> zonesIn(Size scene) {
    final width = scene.width - 2 * side;
    final t = _measure(title, titleStyle, width);
    final d = _measure(date, dateStyle, width);
    double x(Size size) =>
        direction == TextDirection.rtl ? scene.width - side - size.width : side;
    final inline = stripInline(width);
    double stripX() => direction == TextDirection.rtl
        ? side
        : scene.width - side - strip.width;
    return [
      Rect.fromLTWH(x(t), topInset, t.width, t.height),
      Rect.fromLTWH(x(d), topInset + t.height, d.width, d.height),
      if (strip.width > 0)
        Rect.fromLTWH(
          stripX(),
          inline
              ? topInset + math.max(0.0, (t.height - strip.height) / 2)
              : topInset + t.height + d.height + 6,
          strip.width,
          strip.height,
        ),
    ];
  }
}

/// The words and controls of the sky card on a medium or expanded window, so
/// the sun and moon keep clear of them like they do of the phone's header.
class _CardWords {
  const _CardWords({
    required this.title,
    required this.titleStyle,
    required this.date,
    required this.dateStyle,
    required this.scaler,
    required this.direction,
  });

  final String title;
  final TextStyle? titleStyle;
  final String date;
  final TextStyle? dateStyle;
  final TextScaler scaler;
  final TextDirection direction;

  static const padding = 24.0;
  static const top = 16.0;

  /// The three day buttons and the gaps between them.
  static const controlsGap = 8.0;
  static const controls = Size(3 * 48.0 + 2 * controlsGap, 48);
  static const controlsInset = 16.0;

  /// How far the words stay from the card's far edge, clear of the buttons.
  static const textEndInset = controlsInset + 160.0 + 24;

  Size _measure(String text, TextStyle? style, double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: math.max(40.0, width));
    final size = painter.size;
    painter.dispose();
    return size;
  }

  double _room(double cardWidth) => cardWidth - padding - textEndInset;

  /// The card's height: the words with room above and below, never under
  /// the board's 118.
  double heightFor(double cardWidth) {
    final room = _room(cardWidth);
    final t = _measure(title, titleStyle, room);
    final d = _measure(date, dateStyle, room);
    return math.max(118.0, top + t.height + d.height + 22);
  }

  List<Rect> zonesIn(Size scene) {
    final room = _room(scene.width);
    final t = _measure(title, titleStyle, room);
    final d = _measure(date, dateStyle, room);
    double x(Size size) => direction == TextDirection.rtl
        ? scene.width - padding - size.width
        : padding;
    return [
      Rect.fromLTWH(x(t), top, t.width, t.height),
      Rect.fromLTWH(x(d), top + t.height, d.width, d.height),
      Rect.fromLTWH(
        direction == TextDirection.rtl
            ? controlsInset
            : scene.width - controlsInset - controls.width,
        controlsInset,
        controls.width,
        controls.height,
      ),
    ];
  }
}

/// The day sky behind the Today header, starting at the top edge of the
/// screen and drawn twice from one model: the app bar shows its top
/// ([strip]), the header shows the rest. Both move 1:1 with the header, so
/// a mark can never slide over the content that follows it, and the scene's
/// bodies, ground, path and marks fade out as the header collapses
/// ([collapse]); only the sky gradient stays under the app bar. The ground
/// runs on below the header, behind the content, so the sky adds no height.
class _TodaySky extends ConsumerWidget {
  const _TodaySky({
    super.key,
    required this.request,
    required this.date,
    required this.scroll,
    required this.breath,
    required this.ambient,
    required this.height,
    required this.collapse,
    this.pull,
    this.words,
    this.strip = false,
    this.cardHeight,
    this.zones,
  });

  /// The header words; sky bodies and marks keep clear of them.
  final _HeaderWords? words;

  /// Where words and controls sit in a sky card, for the sun and moon to keep
  /// clear of; overrides [words].
  final List<Rect> Function(Size scene)? zones;

  /// Set on a medium or expanded window, where the sky is a fixed card this
  /// high at the top of the page instead of the scrolling header.
  final double? cardHeight;

  final CareDayRequest request;
  final DateTime date;
  final ScrollController scroll;
  final Animation<double> breath;
  final AmbientDrift ambient;

  /// Written by the header, read by the app bar strip.
  final ValueNotifier<double?> height;
  final ValueNotifier<double> collapse;
  final ValueListenable<double>? pull;
  final bool strip;

  /// The horizon sits this far below the header, so single marks rest just
  /// above it, in the free band under the date line.
  static const _horizonBelowHeader = 6.0;
  static const _groundFade = 30.0;

  double _offset() => scroll.hasClients && scroll.positions.length == 1
      ? math.max(0, scroll.offset)
      : 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final loaded = ref.watch(careDayProvider(request)).asData?.value;
    final entries = [
      for (final e in loaded?.entries ?? const <CareDayEntry>[])
        if (e.occurrence.expected || e.occurrence.state != 'pending') e,
    ];
    final doses = [
      for (final e in entries)
        HorizonDose(
          id: e.occurrence.id,
          plannedLocalTime: e.occurrence.plannedLocalTime,
          state: e.occurrence.state,
          person: e.person.name,
        ),
    ];
    final celebrate = ref.watch(_skyCelebrateProvider);
    final sweep = ref.watch(_skySweepProvider);
    final focused = ref.watch(_skyFocusedProvider);
    final highContrast =
        ref.watch(highContrastEnabledProvider) ||
        MediaQuery.highContrastOf(context);
    final recorded = doses
        .where(
          (d) =>
              d.state == 'taken' || d.state == 'skipped' || d.state == 'missed',
        )
        .length;
    final next = entries
        .where((e) => e.occurrence.expected && e.occurrence.state == 'pending')
        .firstOrNull;
    final nextTime = next?.occurrence.plannedLocalTime;
    final label = next == null || nextTime == null
        ? l.sc_skyNoNext(recorded, doses.length)
        : l.sc_skyLabel(recorded, doses.length, clockText(context, nextTime));
    final sunLabel = next == null || nextTime == null
        ? l.sc_sunNone
        : l.sc_sunNext(
            clockText(context, nextTime),
            next.person.name,
            next.snapshot.pillName,
          );
    void focus(String id) => ref
        .read(_skyFocusProvider.notifier)
        .update((old) => (id: id, seq: (old?.seq ?? 0) + 1));
    Widget scene(double height, {bool fade = false}) {
      Widget child = SceneClock(
        builder: (context, now) => HorizonScene.live(
          date: date,
          now: now,
          doses: doses,
          highContrast: highContrast,
          height: height,
          collapse: collapse,
          pull: pull,
          onMarkTapped: focus,
          celebrateId: doses.any((d) => d.id == celebrate) ? celebrate : null,
          // The receipt ring belongs to the card's capsule; the sky mark
          // only twinkles as a small echo.
          celebrateReach: 12,
          focusedId: doses.any((d) => d.id == focused) ? focused : null,
          semanticsLabel: label,
          onShowNext: next == null ? null : () => focus(next.occurrence.id),
          sunLabel: strip ? null : sunLabel,
          onSunScrub: strip ? null : focus,
          showNextLabel: l.sc_showNextDose,
          readNextLabel: l.sc_readNextDose,
          breath: breath,
          ambient: ambient,
          markLocator: strip ? null : ref.read(todaySkyLocatorProvider),
          entryHold: strip ? null : ref.read(todaySunriseHoldProvider),
          sweepId: strip || !doses.any((d) => d.id == sweep) ? null : sweep,
          textZonesFor: zones ?? words?.zonesIn,
        ),
      );
      if (fade) {
        // The ground dissolves into the page instead of ending in an edge.
        child = ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [Colors.white, Colors.white, Color(0x00FFFFFF)],
            stops: [0, 1 - _groundFade / rect.height, 1],
          ).createShader(rect),
          child: child,
        );
      }
      return OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: height,
        maxHeight: height,
        child: child,
      );
    }

    final fixed = cardHeight;
    if (fixed != null) {
      // A card does not scroll: its scene is exactly as tall as the card and
      // its ground, bodies and marks stay where they are.
      return ClipRRect(
        borderRadius: BorderRadius.circular(_skyCardRadius),
        child: scene(fixed),
      );
    }
    if (strip) {
      return ValueListenableBuilder<double?>(
        valueListenable: height,
        builder: (context, value, _) => value == null
            ? const SizedBox.shrink()
            : ClipRect(
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: AnimatedBuilder(
                      animation: scroll,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(0, -_offset()),
                        child: child,
                      ),
                      child: scene(value),
                    ),
                  ),
                ),
              ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final value = ((constraints.maxHeight + _horizonBelowHeader) / .8)
            .ceilToDouble();
        if (height.value != value) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            height.value = value;
          });
        }
        return ClipRect(
          clipper: _SkyClip(value),
          child: scene(value, fade: true),
        );
      },
    );
  }
}

/// Clips to the full scene height, which runs past the header box.
class _SkyClip extends CustomClipper<Rect> {
  const _SkyClip(this.height);
  final double height;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width, height);
  @override
  bool shouldReclip(_SkyClip old) => old.height != height;
}

Future<void> _chooseDate(
  BuildContext context,
  WidgetRef ref,
  DateTime date,
) async {
  final today = DateUtils.dateOnly(DateTime.now()), firstDate = DateTime(2000);
  final picked = await showDatePicker(
    context: context,
    initialDate: date.isBefore(firstDate)
        ? firstDate
        : date.isAfter(today)
        ? today
        : date,
    firstDate: firstDate,
    lastDate: today,
  );
  if (picked != null && context.mounted) {
    ref.read(selectedDateProvider.notifier).select(picked);
  }
}

class _FocusDay extends ConsumerWidget {
  const _FocusDay({super.key, required this.request});
  final CareDayRequest request;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(careDayProvider(request));
    if (state.hasError) {
      return CareState(
        title: l.t08_unavailable,
        body: l.t08_unavailableBody,
        action: () => ref.invalidate(careDayProvider(request)),
        actionLabel: l.shared_retry,
      );
    }
    if (state.asData == null) {
      return CareState(title: l.shared_loading, loading: true);
    }
    final loaded = state.requireValue;
    // Pending PRN sentinels are available actions, never doses still due.
    final day = CareDay(
      localDate: loaded.localDate,
      state: loaded.state,
      people: loaded.people,
      // As-needed doses live in the As needed section, never as deck cards.
      entries: loaded.entries
          .where(
            (e) =>
                e.occurrence.source != 'prn' &&
                (e.occurrence.expected || e.occurrence.state != 'pending'),
          )
          .toList(),
      prn: loaded.prn,
      nextDose: loaded.nextDose,
    );
    if (day.state == CareDayState.noMedications) {
      return _NoMedications(day: day);
    }
    if (day.entries.isEmpty &&
        (day.state == CareDayState.dayOff || day.nextDose != null)) {
      return _ScheduledDayOff(day: day);
    }
    if (day.entries.isNotEmpty) {
      return LayoutReveal(
        family: effectiveLayoutFamily(ref.watch(layoutFamilyProvider)),
        child: FocusDeck(
          day: day,
          family: effectiveLayoutFamily(ref.watch(layoutFamilyProvider)),
          asNeeded: [
            for (final e in loaded.entries)
              if (e.occurrence.source == 'prn' && e.occurrence.state == 'taken')
                e,
          ],
        ),
      );
    }
    // Only as-needed medication: the As needed section below is the day.
    if (day.prn.isNotEmpty) return const SizedBox.shrink();
    final title = switch (day.state) {
      CareDayState.noPeople => l.t08_noPeople,
      CareDayState.noMedications => l.t08_noMedications,
      CareDayState.noRoutine => l.t08_noRoutine,
      CareDayState.asNeeded => l.t08_asNeeded,
      _ => l.t08_dayOff,
    };
    final body = switch (day.state) {
      CareDayState.noRoutine => l.t08_noRoutineBody,
      CareDayState.asNeeded => l.t08_asNeededBody,
      CareDayState.noPeople => l.t10_noPeopleBody,
      CareDayState.noMedications => l.t10_noMedicationBody,
      _ => l.t08_dayOffBody,
    };
    return CareState(
      title: title,
      body: body,
      actionLabel: day.state == CareDayState.noPeople
          ? l.t08_personSave
          : l.t08_medications,
      action: () => context.go(
        day.state == CareDayState.noPeople ? '/setup?purpose=person' : '/pills',
      ),
    );
  }
}

Color _emptyDayBorder(
  BuildContext context,
  WidgetRef ref, {
  bool action = false,
}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final appearance = ref.watch(appearanceNotifierProvider).valueOrNull;
  // Refine the default light treatment without recoloring a chosen border role
  // or reducing the explicit high-contrast treatment.
  if (appearance == null ||
      appearance.lightColors.containsKey(AppearanceColorRole.border) ||
      theme.brightness != Brightness.light ||
      (theme.dividerTheme.thickness ?? 1) > 1 ||
      colors.outlineVariant != AppTheme.light().colorScheme.outlineVariant) {
    return colors.outlineVariant;
  }
  return action
      ? Color.lerp(colors.outline, AppColors.seedSecondary, .7)!
      : AppColors.seedSecondary;
}

class _EmptyDayIllustration extends StatelessWidget {
  const _EmptyDayIllustration({this.calendar = false});
  final bool calendar;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(calendar ? 42 : 64),
    painter: _EmptyDayOutline(
      color: Theme.of(context).colorScheme.onSurface,
      calendar: calendar,
    ),
  );
}

/// Decorative reference illustrations use rounded strokes at a fixed weight;
/// scaling a Material font glyph would also thicken its outline.
class _EmptyDayOutline extends CustomPainter {
  const _EmptyDayOutline({required this.color, required this.calendar});
  final Color color;
  final bool calendar;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64, size.height / 64);
    final stroke = Paint()
      ..color = color
      ..strokeWidth = calendar ? 3 : 2.4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    if (calendar) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(7, 12, 50, 47),
          const Radius.circular(7),
        ),
        stroke,
      );
      for (final x in [20.0, 44.0]) {
        canvas.drawLine(Offset(x, 5), Offset(x, 18), stroke);
      }
      canvas.drawLine(const Offset(8, 26), const Offset(56, 26), stroke);
      final dot = Paint()..color = color;
      for (final y in [36.0, 47.0]) {
        for (final x in [21.0, 32.0, 43.0]) {
          canvas.drawCircle(Offset(x, y), 2, dot);
        }
      }
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(10, 3, 43, 55),
          const Radius.circular(9),
        ),
        stroke,
      );
      canvas.drawLine(const Offset(20, 18), const Offset(43, 18), stroke);
      canvas.drawLine(const Offset(20, 30), const Offset(35, 30), stroke);
      canvas.drawLine(const Offset(20, 42), const Offset(27, 42), stroke);
    }
  }

  @override
  bool shouldRepaint(_EmptyDayOutline oldDelegate) =>
      oldDelegate.color != color || oldDelegate.calendar != calendar;
}

class _EmptyDaySurface extends ConsumerWidget {
  const _EmptyDaySurface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 20),
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border.all(
        color: _emptyDayBorder(context, ref),
        width: Theme.of(context).dividerTheme.thickness ?? 1,
      ),
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );
}

class _NoMedications extends ConsumerWidget {
  const _NoMedications({required this.day});
  final CareDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final person = day.people.length == 1 ? day.people.single : null;
    return _EmptyDaySurface(
      child: Column(
        children: [
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: SizedBox(
              width: 80,
              height: 72,
              child: Stack(
                children: [
                  const Positioned(
                    left: 0,
                    top: 0,
                    child: _EmptyDayIllustration(),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 3,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Icon(
                          Icons.add,
                          color: theme.colorScheme.onPrimary,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            l.r15_noMedications,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            person == null
                ? l.r15_chooseFirstPerson
                : l.r15_addForPerson(person.name),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(shape: const StadiumBorder()),
              onPressed: () async {
                var personId = person?.id;
                if (personId == null) {
                  final captured = ref
                      .read(workspaceContextProvider)
                      .asData
                      ?.value;
                  if (captured == null) return;
                  personId = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (sheetContext) => SafeArea(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text(
                            l.r15_choosePerson,
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          for (final choice in day.people)
                            ListTile(
                              title: Text(choice.name),
                              onTap: () =>
                                  Navigator.of(sheetContext).pop(choice.id),
                            ),
                        ],
                      ),
                    ),
                  );
                  if (!context.mounted) return;
                  final current = ref
                      .read(workspaceContextProvider)
                      .asData
                      ?.value;
                  if (current == null || !sameCareContext(captured, current)) {
                    return;
                  }
                }
                if (personId != null && context.mounted) {
                  context.push(
                    Uri(
                      path: '/setup',
                      queryParameters: {
                        'purpose': 'medication',
                        'person': personId,
                      },
                    ).toString(),
                  );
                }
              },
              child: Text(l.r09_addMedication),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l.r15_optionalSetup,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScheduledDayOff extends ConsumerWidget {
  const _ScheduledDayOff({required this.day});
  final CareDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final next = day.nextDose;
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          day.localDate == routineDateKey(DateTime.now())
              ? l.r15_nothingToday
              : l.r15_nothingDay,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          next == null ? l.r15_noNext : l.r15_nextBody,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final deviceZone = ref.watch(deviceTimeZoneProvider).asData?.value;
    final travel = next == null
        ? null
        : _travelTimeLabel(
            context,
            plannedAt: next.planned.plannedAt,
            savedZone: next.planned.timeZone,
            deviceZone: deviceZone,
          );
    final medication = next == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                next.pill.name,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                careAmountLabel(l, next.amount),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
    return _EmptyDaySurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (large) ...[
            const ExcludeSemantics(
              child: _EmptyDayIllustration(calendar: true),
            ),
            const SizedBox(height: 16),
            title,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ExcludeSemantics(
                  child: _EmptyDayIllustration(calendar: true),
                ),
                const SizedBox(width: 16),
                Expanded(child: title),
              ],
            ),
          if (next != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Divider(height: 1, color: _emptyDayBorder(context, ref)),
            ),
            Text(
              l.r15_nextDate(
                DateFormat.yMMMEd(
                  Localizations.localeOf(context).toString(),
                ).format(parseRoutineDate(next.planned.localDate)),
              ),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (day.people.length > 1) ...[
              const SizedBox(height: 6),
              Text(l.t08_forPerson(next.person.name)),
            ],
            const SizedBox(height: 16),
            if (large) ...[
              ClockText(
                clockText(context, next.planned.localTime),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              medication!,
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClockText(
                    clockText(context, next.planned.localTime),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.only(left: 16),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: _emptyDayBorder(context, ref),
                          ),
                        ),
                      ),
                      child: medication,
                    ),
                  ),
                ],
              ),
            if (travel != null) ...[
              const SizedBox(height: 12),
              Text(travel, style: theme.textTheme.bodySmall),
            ],
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurface,
                side: BorderSide(
                  color: _emptyDayBorder(context, ref, action: true),
                  width: theme.dividerTheme.thickness ?? 1,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => context.push(
                next == null ? '/pills' : '/pills/${next.pill.id}/routine',
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      next == null ? l.t08_medications : l.r09_viewRoutine,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selection belongs to an exact occurrence, never an index in the live list.
///
/// This State also hosts every alternative Today layout ([family]): it owns
/// the one guarded record path and the receipts, and lives under the Today
/// identity key, so a layout gets the same safety by receiving a
/// [TodayLayoutData] built here instead of recording on its own.
class FocusDeck extends ConsumerStatefulWidget {
  const FocusDeck({
    super.key,
    required this.day,
    this.family = LayoutFamily.focusDeck,
    this.asNeeded = const [],
  });
  final CareDay day;

  /// As-needed doses already recorded on [day]. Focus deck ignores them (the
  /// As needed section shows them); the other layouts place each one at the
  /// time it was taken.
  final List<CareDayEntry> asNeeded;

  /// Which layout renders the doses. Unavailable families show Focus deck.
  final LayoutFamily family;
  @override
  ConsumerState<FocusDeck> createState() => _FocusDeckState();
}

class _FocusDeckState extends ConsumerState<FocusDeck>
    with WidgetsBindingObserver {
  String? _focused;
  bool _backgrounded = false;
  String? _busyId;
  String? _error;
  final Map<String, ({CareRecordingService service, PreparedCareIntent intent})>
  _pending = {};
  final Map<String, CareRecordingReceipt> _saved = {};

  /// The one receipt that may play its moment. Set only by the `setState`
  /// that stores a durable receipt, so syncs, notification actions and
  /// rebuilt cards never celebrate; cleared when the moment ends.
  ReceiptMoment? _moment;

  /// Receipt event id whose take brought the day to zero remaining.
  String? _settle;

  /// The dose whose sky mark twinkles once its check has flown there (or, if
  /// no flight can play, at once).
  /// Every take still on its way to the sky, each with its own fallback
  /// timer, so a quick second take cannot swallow the first one's twinkle.
  final Map<String, Timer> _landing = {};

  /// The settling take whose landing also plays the day's sweep.
  String? _sweepOnLanding;

  /// Moments already played; a card rebuilt mid-moment shows the final frame.
  final Set<String> _played = {};
  bool _claim(String token) => _played.add(token);

  void _momentDone(String token) {
    if (!mounted) return;
    if (_moment?.token == token || _settle == token) {
      setState(() {
        if (_moment?.token == token) _moment = null;
        if (_settle == token) _settle = null;
      });
    }
  }

  /// Haptics answer only a visible, current Today.
  bool get _canFeel =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.isCurrentOf(context) ?? true);

  MedicationOccurrence _rowOf(CareDayEntry entry) {
    final saved = _saved[entry.occurrence.id];
    return saved != null &&
            saved.current.stateVersion >= entry.occurrence.stateVersion
        ? saved.current
        : entry.occurrence;
  }

  /// A receipt tells how sharing stood at the moment of saving. Once the day
  /// has read that same save back, the day's reading is the newer one: a
  /// sync may have sent the record since, without changing its state.
  CareSharingOutcome _sharingOf(CareDayEntry entry) {
    final saved = _saved[entry.occurrence.id];
    return saved != null &&
            saved.current.stateVersion > entry.occurrence.stateVersion
        ? saved.sharing
        : entry.sharing;
  }

  int _remaining() => widget.day.entries
      .where((e) => e.occurrence.expected && _rowOf(e).state == 'pending')
      .length;

  int _missedCount() => widget.day.entries
      .where((e) => e.occurrence.expected && _rowOf(e).state == 'missed')
      .length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focused = widget.day.entries.firstOrNull?.occurrence.id;
  }

  @override
  void dispose() {
    for (final t in _landing.values) {
      t.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The check flies from its card to the dose's sky mark; the mark twinkles
  /// when it arrives. Only a durable take starts one (see `ReceiptCapsule`).
  void _fly(String id, Offset from) {
    if (!mounted || !_landing.containsKey(id)) return;
    final to = ref.read(todaySkyLocatorProvider).globalCenterOf(id);
    if (to == null) return;
    playCapsuleFlight(context, from: from, to: to).whenComplete(() {
      _landed(id);
    });
  }

  void _landed(String id) {
    final timer = _landing.remove(id);
    if (timer == null) return;
    timer.cancel();
    _twinkle(id);
  }

  void _twinkle(String id) {
    if (!mounted) return;
    ref.read(_skyCelebrateProvider.notifier).state = id;
    if (_sweepOnLanding == id) {
      _sweepOnLanding = null;
      ref.read(_skySweepProvider.notifier).state = id;
    }
  }

  /// Twinkle the mark when the flight lands; with no flight to wait for
  /// (quiet motion, mark off screen) it twinkles now. A timer covers a flight
  /// that never starts, e.g. a card scrolled out of the way.
  void _celebrateOnLanding(String id) {
    _landing.remove(id)?.cancel();
    final canFly =
        !AppMotion.quiet(context) &&
        ref.read(todaySkyLocatorProvider).globalCenterOf(id) != null;
    if (!canFly) {
      _twinkle(id);
      return;
    }
    _landing[id] = Timer(
      skyFlightDuration + const Duration(milliseconds: 500),
      () => _landed(id),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      if (_backgrounded) ref.invalidate(deviceTimeZoneProvider);
      _backgrounded = false;
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _backgrounded = true;
    }
  }

  @override
  void didUpdateWidget(FocusDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.day.entries.any((entry) => entry.occurrence.id == _focused)) {
      _focused = widget.day.entries.firstOrNull?.occurrence.id;
    }
  }

  Future<void> _record(CareDayEntry entry, {required bool undo}) async {
    if (_busyId != null) return;
    final id = entry.occurrence.id;
    final actionKey = '$id/${undo ? 'undo' : 'take'}';
    // Promise: the touch is acknowledged at once; the receipt waits for disk.
    if (!undo && _canFeel) HapticFeedback.selectionClick();
    setState(() {
      _busyId = id;
      _error = null;
    });
    try {
      var prepared = _pending[actionKey];
      if (prepared == null) {
        final captured = ref.read(workspaceContextProvider).asData?.value;
        if (captured == null) return;
        final service = await ref.read(careRecordingServiceProvider.future);
        if (!mounted ||
            !sameCareContext(captured, service.context) ||
            !careServiceIsCurrent(ref, service)) {
          return;
        }
        final saved = _saved[id];
        final current =
            saved != null &&
                saved.current.stateVersion >= entry.occurrence.stateVersion
            ? saved.current
            : entry.occurrence;
        final head =
            saved != null &&
                saved.current.stateVersion >= entry.occurrence.stateVersion
            ? saved.event
            : entry.head;
        final intent = undo
            ? await service.prepareUndoForEntry(
                personId: entry.person.id,
                occurrenceId: id,
                expectedStateVersion: current.stateVersion,
                headEventId: head!.id,
              )
            : await service.prepareTakenNow(
                personId: entry.person.id,
                occurrenceId: id,
                expectedStateVersion: current.stateVersion,
                amount: entry.plannedAmount,
              );
        prepared = (service: service, intent: intent);
        _pending[actionKey] = prepared;
      }
      // A cached intent (retry path) skipped the checks above, and preparing
      // awaited: re-check that this care context is still the current one.
      final current = ref.read(workspaceContextProvider).asData?.value;
      if (!mounted ||
          current == null ||
          !sameCareContext(current, prepared.service.context) ||
          !careServiceIsCurrent(ref, prepared.service)) {
        _pending.remove(actionKey);
        return;
      }
      final receipt = await prepared.service.commit(prepared.intent);
      if (!mounted) return;
      await prepared.service.access.requireCurrent(prepared.service.context);
      if (!mounted) return;
      final before = _remaining();
      var settles = false;
      setState(() {
        _saved[id] = receipt;
        _pending.remove(actionKey);
        _moment = (occurrenceId: id, token: receipt.event.id, undo: undo);
        if (!undo && before > 0 && _remaining() == 0) {
          _settle = receipt.event.id;
          settles = true;
        }
      });
      // The sky sweeps once per day, when the day first comes to rest.
      // Keyed by workspace, chosen person and date, so settling another
      // person's day (or another workspace's) is a new day for the sky.
      final sweepKey =
          '${prepared.service.context.workspaceId}/${ref.read(selectedProfileIdProvider)}/'
          '${widget.day.localDate}';
      final swept = ref.read(_sweptDaysProvider);
      if (settles && !swept.contains(sweepKey)) {
        ref.read(_sweptDaysProvider.notifier).state = {...swept, sweepKey};
        _sweepOnLanding = id;
      } else {
        _sweepOnLanding = null;
      }
      // The sky mark twinkles for this durable take only, once its check has
      // flown there.
      if (undo) {
        _landing.remove(id)?.cancel();
        ref.read(_skyCelebrateProvider.notifier).state = null;
      } else {
        _celebrateOnLanding(id);
      }
      // The undo is saved, but the phone's stock count stays as it was: say so,
      // so the person can correct it by hand.
      if (undo && receipt.stock == CareStockOutcome.unchanged && mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).t08_undoStockUnchanged),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      // Receipt: one haptic, only after the durable commit.
      if (_canFeel) {
        // One haptic per receipt; settling the day adds none of its own.
        undo ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
      }
    } on Object catch (error) {
      // Cause only: the fixed block code or the exception type, never a
      // message or any medication data.
      AppLogger.warning(
        'FocusDeck',
        '${undo ? 'undo' : 'take'} failed: '
            '${error is MedicationCommandBlocked ? error.code : error.runtimeType}',
      );
      // A refused command (stale version, conflict) can never succeed on
      // replay: prepare a fresh one on retry. Other failures keep the cached,
      // idempotent command.
      if (error is MedicationCommandBlocked) _pending.remove(actionKey);
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).t08_recordError);
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  String _sharing(AppLocalizations l, CareSharingOutcome outcome) =>
      todaySharingLabel(l, outcome);

  bool _canSelect() => widget.day.entries.any(
    (e) =>
        e.occurrence.expected && e.canRecord && e.occurrence.state == 'pending',
  );

  Future<void> _selectDoses() async {
    final captured = ref.read(workspaceContextProvider).asData?.value;
    if (captured == null) return;
    final service = await ref.read(careRecordingServiceProvider.future);
    if (!mounted ||
        !sameCareContext(captured, service.context) ||
        !careServiceIsCurrent(ref, service)) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SelectedDosesReview(
          day: widget.day,
          service: service,
          personId: widget.day.people.length == 1
              ? widget.day.people.single.id
              : null,
        ),
      ),
    );
  }

  /// Dose details: the right pane of an expanded window, the full-page route
  /// everywhere else.
  void _openDetails(CareDayEntry entry) {
    if (_busyId != null) return;
    if (WindowClass.of(context).isExpanded) {
      setState(() {
        _focused = entry.occurrence.id;
        _error = null;
      });
      ref.read(todayDetailsProvider.notifier).state = entry.occurrence.id;
    } else {
      context.push('/doses/${entry.occurrence.id}');
    }
  }

  Future<void> _openOverview() async {
    final result = await showDayOverview(
      context,
      widget.day.entries,
      _focused,
      localDate: widget.day.localDate,
    );
    if (result != null && mounted) {
      setState(() {
        _focused = result;
        _error = null;
      });
    }
  }

  /// "Other time" and "Skip": the same review form Dose details opens, with
  /// the same prepare call. Nothing is written until the form is saved.
  Future<void> _recordWithForm(CareDayEntry entry, {required bool skip}) async {
    if (_busyId != null) return;
    final captured = ref.read(workspaceContextProvider).asData?.value;
    if (captured == null) return;
    final service = await ref.read(careRecordingServiceProvider.future);
    if (!mounted ||
        !sameCareContext(captured, service.context) ||
        !careServiceIsCurrent(ref, service)) {
      return;
    }
    final row = _rowOf(entry);
    await openCareRecordForm(
      context,
      service: service,
      personId: entry.person.id,
      personName: entry.person.name,
      medicationName: entry.snapshot.pillName,
      occurrenceId: row.id,
      localDate: row.plannedLocalDate,
      state: row.state,
      stateVersion: row.stateVersion,
      amount: entry.plannedAmount,
      skip: skip,
    );
  }

  /// The seam for alternative layouts: this State's data and its own guarded
  /// actions, rebuilt every frame and never stored elsewhere.
  TodayLayoutData _layoutData(
    AsyncValue<String> deviceZone, {
    List<StockRow> lowStock = const [],
    bool canAddStock = false,
  }) {
    bool useSaved(CareDayEntry entry) {
      final saved = _saved[entry.occurrence.id];
      return saved != null &&
          saved.current.stateVersion >= entry.occurrence.stateVersion;
    }

    return TodayLayoutData(
      day: widget.day,
      asNeeded: widget.asNeeded,
      focusedId: _focused,
      busyId: _busyId,
      error: _error,
      rowOf: _rowOf,
      headOf: (entry) =>
          useSaved(entry) ? _saved[entry.occurrence.id]!.event : entry.head,
      sharingOf: _sharingOf,
      momentOf: (id) => _moment?.occurrenceId == id ? _moment : null,
      settleToken: _settle,
      claimMoment: _claim,
      onMomentDone: _momentDone,
      travelTimeOf: (row) => deviceZone.isLoading
          ? null
          : _travelTimeLabel(
              context,
              plannedAt: row.plannedAt,
              savedZone: row.timeZone,
              deviceZone: deviceZone.asData?.value,
            ),
      isToday: widget.day.localDate == routineDateKey(DateTime.now()),
      onTake: (entry) => _record(entry, undo: false),
      onUndo: (entry) => _record(entry, undo: true),
      onFocus: (id) {
        if (!mounted || !widget.day.entries.any((e) => e.occurrence.id == id)) {
          return;
        }
        setState(() {
          _focused = id;
          _error = null;
        });
      },
      onOpenDetails: _openDetails,
      onOpenOverview: _openOverview,
      lowStock: lowStock,
      onAddStock: canAddStock
          ? (row) => openStockEditor(context, ref, row.pillId)
          : null,
      onDismissLowStock: (row) =>
          ref.read(lowStockDismissalsProvider.notifier).dismiss(row.pillId),
      onSelectDoses: _canSelect()
          ? () {
              if (_busyId == null) _selectDoses();
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) =>
      SkyFlightScope(launch: _fly, child: _buildDeck(context));

  Widget _buildDeck(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final entries = widget.day.entries;
    // A tapped sky mark focuses that exact occurrence, if it is in this deck.
    ref.listen(_skyFocusProvider, (_, request) {
      if (request == null ||
          !widget.day.entries.any((e) => e.occurrence.id == request.id)) {
        return;
      }
      setState(() {
        _focused = request.id;
        _error = null;
      });
    });
    if (entries.isEmpty) return const SizedBox.shrink();
    final phone = WindowClass.of(context) == WindowClass.compact;
    // Tell the sky which card is focused (after the frame: no provider
    // writes during build).
    final shown = entries.any((e) => e.occurrence.id == _focused)
        ? _focused
        : entries.first.occurrence.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final focused = ref.read(_skyFocusedProvider.notifier);
      if (focused.state != shown) focused.state = shown;
    });
    final layout = widget.family == LayoutFamily.focusDeck
        ? null
        : todayLayouts[widget.family];
    // Low-stock notices belong to the phone's Today, and only to today: the
    // tablet and medium windows carry the Stock card instead.
    final lowStock =
        phone && widget.day.localDate == routineDateKey(DateTime.now())
        ? ref.watch(lowStockNoticesProvider)
        : const <StockRow>[];
    final canAddStock =
        lowStock.isNotEmpty &&
        (ref.watch(todayStockProvider).asData?.value.canAddStock ?? false);
    if (layout != null) {
      return layout(
        context,
        _layoutData(
          ref.watch(deviceTimeZoneProvider),
          lowStock: lowStock,
          canAddStock: canAddStock,
        ),
      );
    }
    final index = entries
        .indexWhere((e) => e.occurrence.id == _focused)
        .clamp(0, entries.length - 1);
    final entry = entries[index];
    final busy = _busyId != null;
    final deviceZone = ref.watch(deviceTimeZoneProvider);
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final canSelect = _canSelect();
    void focus(int target) => setState(() {
      _focused = entries[target].occurrence.id;
      _error = null;
    });
    Widget cardFor(CareDayEntry entry, bool actionable) {
      final saved = _saved[entry.occurrence.id];
      final useSaved =
          saved != null &&
          saved.current.stateVersion >= entry.occurrence.stateVersion;
      final row = useSaved ? saved.current : entry.occurrence;
      final head = useSaved ? saved.event : entry.head;
      final pending = row.state == 'pending';
      final missed = row.state == 'missed';
      final late = isTakenLate(row.state, head);
      final saving = _busyId == entry.occurrence.id;
      final moment = _moment?.occurrenceId == entry.occurrence.id
          ? _moment
          : null;
      final travelTime = deviceZone.isLoading
          ? null
          : _travelTimeLabel(
              context,
              plannedAt: row.plannedAt,
              savedZone: row.timeZone,
              deviceZone: deviceZone.asData?.value,
            );
      final amount = entry.plannedAmount.isUnknown
          ? '${l.t08_amount}: ${l.t08_unknown}'
          : '${entry.plannedAmount.quantityText} ${entry.plannedAmount.unit}';
      final hour = int.tryParse(row.plannedLocalTime?.split(':').first ?? '');
      final period = hour == null
          ? l.t08_asNeeded
          : hour >= 5 && hour < 12
          ? l.r07_morning
          : hour < 18 && hour >= 12
          ? l.r07_afternoon
          : hour >= 18 && hour < 22
          ? l.r07_evening
          : l.r07_night;
      Widget chip(String label, {bool state = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: state
              ? colors.surfaceContainerHighest
              : colors.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: text.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: state
                ? semantic.forState(row.state)
                : colors.onPrimaryContainer,
          ),
        ),
      );
      final actionStyle = FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      );
      return _ReferenceDoseSurface(
        key: entry.occurrence.id == _focused
            ? const ValueKey('focus-current-card')
            : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 190),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: chip(period),
                    ),
                  ),
                  // The medication's own colour and shape, as on its tile.
                  // It sits in this row so the name keeps its full width.
                  MedicationMark(
                    key: ValueKey('focus-mark-${entry.occurrence.id}'),
                    size: 30,
                    color: medicationTint(
                      id: entry.pill.id,
                      color: entry.pill.color,
                    ),
                    shape: medicationShapeOf(entry.plannedAmount.unit),
                  ),
                  const SizedBox(width: 8),
                  ReceiptCapsule(
                    key: ValueKey('focus-capsule-${entry.occurrence.id}'),
                    taken: row.state == 'taken',
                    moment: moment,
                    claim: _claim,
                    onDone: _momentDone,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClockText(
                plannedTimeLabel(context, row),
                style: text.headlineLarge?.copyWith(
                  fontSize: large ? 40 : 48,
                  height: 1.05,
                  letterSpacing: -1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (travelTime != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    travelTime,
                    key: const ValueKey('focus-travel-time'),
                    style: text.bodySmall,
                  ),
                ),
              if (widget.day.people.length != 1)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l.t08_forPerson(entry.person.name),
                    style: text.labelLarge,
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                entry.snapshot.pillName,
                style: text.titleLarge?.copyWith(
                  fontSize: 23,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                amount,
                style: text.bodyLarge?.copyWith(
                  fontSize: 17,
                  color: colors.onSurfaceVariant,
                ),
              ),
              if (entry.snapshot.dosage?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(entry.snapshot.dosage!, style: text.bodyMedium),
                ),
              const SizedBox(height: 8),
              ReceiptSwap(
                receipt: ReceiptSwap.of(row.state, row.stateVersion),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      liveRegion: !pending,
                      child: chip(
                        pending
                            ? l.t08_unrecorded
                            : row.state == 'taken'
                            ? (late ? l.dose_takenLate : l.t08_taken)
                            : missed
                            ? l.dashboard_statusMissed
                            : l.t08_skipped,
                        state: true,
                      ),
                    ),
                    if (pending && widget.day.state == CareDayState.laterDue)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          l.t08_later,
                          style: text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (!pending && !missed && head != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          head.actualTimeKnown && head.actualAt != null
                              ? clockAt(
                                  context,
                                  tz.TZDateTime.from(
                                    head.actualAt!,
                                    tz.getLocation(row.timeZone),
                                  ),
                                )
                              : l.t08_unknownTime,
                          style: text.bodyMedium,
                        ),
                      ),
                    // One receipt, one frame sequence: the state words, the
                    // action and the sharing line change behind the same key,
                    // so Undo and "Saved" never precede the Taken state.
                    const SizedBox(height: 12),
                    if (pending || missed)
                      SavingPressable(
                        saving: saving,
                        radius: BorderRadius.circular(15),
                        child: FilledButton.icon(
                          key: entry.occurrence.id == _focused
                              ? const ValueKey('focus-taken')
                              : null,
                          style: actionStyle,
                          // Looks enabled on neighbours and mid-travel so focus
                          // changes never flash a grey button; the strip blocks
                          // pointer and focus, and the guard blocks the rest.
                          onPressed: busy || !entry.canRecord
                              ? null
                              : () {
                                  if (actionable) _record(entry, undo: false);
                                },
                          icon: const Icon(Icons.check_circle_outline),
                          label: Text(
                            saving
                                ? l.sc_saving
                                : missed
                                ? l.dose_takeLateNow
                                : l.t08_takenNow,
                          ),
                        ),
                      )
                    else if (head != null && head.action != 'undo')
                      SavingPressable(
                        saving: saving,
                        radius: BorderRadius.circular(15),
                        // Undo is the way back, not the main act: outlined,
                        // as in every other layout, so it never reads as the
                        // call to action the Taken button was.
                        child: OutlinedButton.icon(
                          key: entry.occurrence.id == _focused
                              ? const ValueKey('focus-undo')
                              : null,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(54),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                          onPressed: busy
                              ? null
                              : () {
                                  if (actionable) _record(entry, undo: true);
                                },
                          icon: const Icon(Icons.undo),
                          label: Text(saving ? l.sc_saving : l.t08_undo),
                        ),
                      ),
                    if (missed && head != null && head.action != 'undo')
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SavingPressable(
                          saving: saving,
                          radius: BorderRadius.circular(15),
                          child: OutlinedButton.icon(
                            key: entry.occurrence.id == _focused
                                ? const ValueKey('focus-undo')
                                : null,
                            style: OutlinedButton.styleFrom(
                              minimumSize: actionStyle.minimumSize?.resolve({}),
                            ),
                            onPressed: busy
                                ? null
                                : () {
                                    if (actionable) _record(entry, undo: true);
                                  },
                            icon: const Icon(Icons.undo),
                            label: Text(saving ? l.sc_saving : l.t08_undo),
                          ),
                        ),
                      ),
                    // Taken at another time, or skipped: the same review form
                    // as Dose details. The phone reaches both from Dose
                    // details, which keeps the card as small as it was.
                    if ((pending || missed) && !phone) ...[
                      const SizedBox(height: 10),
                      _OtherActions(
                        keyed: entry.occurrence.id == _focused,
                        stacked: large,
                        enabled: !busy && entry.canRecord && actionable,
                        onOtherTime: () => _recordWithForm(entry, skip: false),
                        onSkip: () => _recordWithForm(entry, skip: true),
                      ),
                    ],
                    if (!pending)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: DurableSaveFeedback(
                          label: _sharing(l, _sharingOf(entry)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final position = Text(
      l.t08_position(index + 1, entries.length),
      style: text.bodySmall,
    );
    final previous = TextButton.icon(
      key: const ValueKey('focus-previous'),
      onPressed: index == 0 ? null : () => focus(index - 1),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(48, 48),
        textStyle: text.labelLarge,
      ),
      icon: const Icon(Icons.chevron_left, size: 20),
      label: Text(l.t08_previous),
    );
    final next = TextButton.icon(
      key: const ValueKey('focus-next'),
      onPressed: index == entries.length - 1 ? null : () => focus(index + 1),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(48, 48),
        textStyle: text.labelLarge,
      ),
      iconAlignment: IconAlignment.end,
      icon: const Icon(Icons.chevron_right, size: 20),
      label: Text(l.t08_next),
    );
    final further = index + 2 < entries.length ? entries[index + 2] : null;
    final secondaryStyle = OutlinedButton.styleFrom(
      side: BorderSide(color: colors.primary.withValues(alpha: .7)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    );
    final details = Pressable(
      radius: BorderRadius.circular(15),
      child: OutlinedButton.icon(
        style: secondaryStyle,
        onPressed: busy ? null : () => _openDetails(entry),
        icon: const Icon(Icons.more_horiz),
        label: Text(l.t10_details),
      ),
    );
    final selection = Pressable(
      radius: BorderRadius.circular(15),
      child: OutlinedButton.icon(
        style: secondaryStyle,
        onPressed: busy ? null : _selectDoses,
        icon: const Icon(Icons.checklist),
        label: Text(l.t10_select),
      ),
    );
    // Counts follow the receipt this State holds, not a later provider tick.
    final remaining = _remaining();
    final hasExpected = entries.any((e) => e.occurrence.expected);
    final missedCount = _missedCount();
    final allRecorded =
        hasExpected &&
        remaining == 0 &&
        missedCount == 0 &&
        widget.day.localDate == routineDateKey(DateTime.now());
    final countLabel = SettleHalo(
      token: _settle,
      claim: _claim,
      onDone: _momentDone,
      child: Semantics(
        liveRegion: allRecorded,
        child: RollingLabel(
          text: !hasExpected
              ? l.t10_recordHistory
              : allRecorded
              ? l.sc_allRecorded
              : remaining == 0 && missedCount > 0
              ? l.dose_missedCount(missedCount)
              : l.t08_remaining(remaining),
          style: text.labelLarge,
        ),
      ),
    );
    final overviewButton = TextButton.icon(
      onPressed: _openOverview,
      style: TextButton.styleFrom(
        // The leading gap is the button's own, so the count, which wraps
        // within its half, never touches the icon at larger text.
        padding: const EdgeInsetsDirectional.only(start: 8),
        textStyle: text.labelLarge,
      ),
      icon: const Icon(Icons.view_list_outlined, size: 19),
      label: Text(l.t08_overview),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (large)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              countLabel,
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: overviewButton,
              ),
            ],
          )
        else
          Row(
            key: const ValueKey('focus-count-row'),
            children: [
              Expanded(child: countLabel),
              Flexible(child: overviewButton),
            ],
          ),
        // The sub-line arrives with the receipt: it grows in, so the card
        // below eases down instead of jumping at the moment of receipt.
        _GrowIn(
          key: const ValueKey('focus-known-outcomes'),
          child:
              widget.day.state == CareDayState.recorded &&
                  entries.any((e) => e.occurrence.expected)
              ? Padding(
                  key: const ValueKey('known'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(l.t10_knownOutcomes),
                )
              : null,
        ),
        for (final row in lowStock)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: LowStockSlim(
              row: row,
              onAddStock: canAddStock
                  ? () => openStockEditor(context, ref, row.pillId)
                  : null,
            ),
          ),
        DoseCardStrip(
          ids: [for (final item in entries) item.occurrence.id],
          labels: [
            for (final item in entries)
              '${item.snapshot.pillName}, ${plannedTimeLabel(context, item.occurrence)}',
          ],
          selectedId: entry.occurrence.id,
          fullWidth: large,
          enabled: !busy,
          onSelected: (id) => setState(() {
            _focused = id;
            _error = null;
          }),
          cardBuilder: (index, actionable) =>
              cardFor(entries[index], actionable),
        ),
        if (large) ...[
          const SizedBox(height: 10),
          Center(child: position),
          Row(
            children: [
              Expanded(child: previous),
              Expanded(child: next),
            ],
          ),
        ] else
          Row(
            children: [
              Expanded(child: previous),
              position,
              Expanded(child: next),
            ],
          ),
        if (further != null) ...[
          Pressable(
            radius: BorderRadius.circular(16),
            child: Material(
              color: colors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: .5),
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => focus(index + 2),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.schedule,
                          size: 23,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          further.occurrence.state == 'pending' &&
                                  (further.occurrence.plannedAt?.isAfter(
                                        DateTime.now(),
                                      ) ??
                                      false)
                              ? l.r07_laterDose(
                                  further.snapshot.pillName,
                                  plannedTimeLabel(context, further.occurrence),
                                )
                              : l.r07_otherDose(
                                  further.snapshot.pillName,
                                  plannedTimeLabel(context, further.occurrence),
                                ),
                          style: text.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right, size: 21),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        if (large || !canSelect) ...[
          details,
          if (canSelect)
            Padding(padding: const EdgeInsets.only(top: 8), child: selection),
        ] else
          Row(
            children: [
              Expanded(child: details),
              const SizedBox(width: 10),
              Expanded(child: selection),
            ],
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(_error!, style: TextStyle(color: colors.error)),
            ),
          ),
      ],
    );
  }
}

/// "Other time" and "Skip" under Taken now, shown on the tablet.
class _OtherActions extends StatelessWidget {
  const _OtherActions({
    required this.keyed,
    required this.stacked,
    required this.enabled,
    required this.onOtherTime,
    required this.onSkip,
  });
  final bool stacked;
  final bool enabled;

  /// Only the focused card carries the keys, as with Taken now.
  final bool keyed;
  final VoidCallback onOtherTime, onSkip;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(48),
      side: BorderSide(color: colors.primary.withValues(alpha: .7)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    );
    final other = Pressable(
      radius: BorderRadius.circular(15),
      child: OutlinedButton.icon(
        key: keyed ? const ValueKey('focus-other-time') : null,
        style: style,
        onPressed: enabled ? onOtherTime : null,
        icon: const Icon(Icons.schedule, size: 20),
        label: Text(l.tt_otherTime),
      ),
    );
    final skip = Pressable(
      radius: BorderRadius.circular(15),
      child: OutlinedButton.icon(
        key: keyed ? const ValueKey('focus-skip') : null,
        style: style,
        onPressed: enabled ? onSkip : null,
        icon: const Icon(Icons.block, size: 20),
        label: Text(l.shared_skip),
      ),
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [other, const SizedBox(height: 8), skip],
      );
    }
    return Row(
      children: [
        Expanded(child: other),
        const SizedBox(width: 10),
        Expanded(child: skip),
      ],
    );
  }
}

/// A line that appears or leaves with a change of state grows and fades in
/// place, so what follows it eases instead of jumping. Quiet mode swaps it.
class _GrowIn extends StatelessWidget {
  const _GrowIn({super.key, this.child});
  final Widget? child;
  @override
  Widget build(BuildContext context) {
    const none = SizedBox(key: ValueKey('none'), width: double.infinity);
    if (AppMotion.quiet(context)) return child ?? none;
    return AnimatedSize(
      duration: AppMotion.standard,
      curve: AppMotion.curve,
      alignment: AlignmentDirectional.topStart,
      child: AnimatedSwitcher(
        duration: AppMotion.standard,
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.topStart,
          children: [...previous, if (current != null) current],
        ),
        child: child ?? none,
      ),
    );
  }
}

class _ReferenceDoseSurface extends StatelessWidget {
  const _ReferenceDoseSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .5)),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .045),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      // The receipt ring washes out from the capsule and stays in the card.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }
}

/// Display conversion never changes the saved routine's zone or planned instant.
String? _travelTimeLabel(
  BuildContext context, {
  required DateTime? plannedAt,
  required String savedZone,
  required String? deviceZone,
}) {
  if (plannedAt == null || savedZone == deviceZone) return null;
  final l = AppLocalizations.of(context);
  final saved = tz.TZDateTime.from(plannedAt, tz.getLocation(savedZone));
  final here = deviceZone == null
      ? null
      : tz.TZDateTime.from(plannedAt, tz.getLocation(deviceZone));
  final differentDate =
      here != null &&
      (saved.year != here.year ||
          saved.month != here.month ||
          saved.day != here.day);
  String timeLabel(DateTime value) {
    final time = TimeOfDay.fromDateTime(value).format(context);
    return differentDate
        ? '${DateFormat.yMMMd(Localizations.localeOf(context).toString()).format(value)}, $time'
        : time;
  }

  String place;
  if (savedZone == 'Europe/Bucharest') {
    place = l.t08_bucharest;
  } else if (savedZone.contains('/') && !savedZone.startsWith('Etc/')) {
    place = savedZone.split('/').last.replaceAll('_', ' ');
  } else {
    final minutes = saved.timeZoneOffset.inMinutes;
    final magnitude = minutes.abs();
    place = minutes == 0
        ? 'UTC'
        : 'UTC${minutes < 0 ? '−' : '+'}${(magnitude ~/ 60).toString().padLeft(2, '0')}:${(magnitude % 60).toString().padLeft(2, '0')}';
  }
  final original = l.t08_savedPlaceTime(timeLabel(saved), place);
  return here == null
      ? original
      : '$original · ${l.t08_hereTime(timeLabel(here))}';
}
