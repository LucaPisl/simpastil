import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/profiles/profile_provider.dart';
import '../../features/setup/setup_controller.dart';
import 'package:go_router/go_router.dart';
import '../../l10n/app_localizations.dart';
import '../motion/app_motion.dart';
import '../router/app_router.dart';
import '../router/back_policy.dart';
import '../widgets/capsule_mark.dart';
import 'tab_hand_off.dart';
import 'window_size.dart';

/// Where Back lands from a page that is the only one of its tab, per tab.
const _tabRoots = [
  AppPaths.home,
  AppPaths.pills,
  AppPaths.logs,
  AppPaths.profiles,
];

/// The one place system Back is decided once nothing above the shell is left
/// to close (sheets, dialogs and pushed pages pop first, in the navigators
/// that hold them).
///
/// 1. An embedded screen with its own steps (first-run setup) steps back.
/// 2. A page that is alone in its tab (opened with `go()`) goes to its tab.
/// 3. Any tab other than Today goes to Today.
/// 4. Today asks for Back once more within [_exitWindow], then exits.
class FocusShell extends ConsumerStatefulWidget {
  const FocusShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;
  @override
  ConsumerState<FocusShell> createState() => _FocusShellState();
}

const _exitWindow = Duration(seconds: 2);

class _FocusShellState extends ConsumerState<FocusShell> {
  Timer? _exitArmed;

  StatefulNavigationShell get navigationShell => widget.navigationShell;

  @override
  void dispose() {
    _exitArmed?.cancel();
    super.dispose();
  }

  /// Opens a tab. Choosing the tab that is already open returns it to its
  /// first page, as everywhere else on the platform.
  void _select(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  void _back() {
    if (ref.read(shellBackInterceptorProvider)?.call() ?? false) return;
    final index = navigationShell.currentIndex;
    final uri = GoRouterState.of(context).uri;
    final root = _tabRoots[index.clamp(0, _tabRoots.length - 1)];
    if (uri.path != root || uri.queryParameters.containsKey('dose')) {
      context.go(root);
      return;
    }
    if (index != 0) {
      navigationShell.goBranch(0);
      return;
    }
    if (_exitArmed?.isActive ?? false) {
      _exitArmed!.cancel();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      SystemNavigator.pop();
      return;
    }
    _exitArmed = Timer(_exitWindow, () {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).nav_pressBackAgain),
          duration: _exitWindow,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: NotificationListener<NavigationNotification>(
        onNotification: _claimBack,
        child: _buildShell(context),
      ),
    );
  }

  /// Each tab's own navigator reports "nothing to pop" after the shell's
  /// [PopScope] has reported that it handles Back, and the last report wins
  /// at the platform: Android then runs its default Back and leaves the app.
  /// The shell handles Back whatever its tabs hold, so say so again from here.
  bool _claimBack(NavigationNotification notification) {
    if (notification.canHandlePop) return false;
    const NavigationNotification(canHandlePop: true).dispatch(context);
    return true;
  }

  Widget _buildShell(BuildContext context) {
    final l = AppLocalizations.of(context);
    final path = GoRouterState.of(context).matchedLocation;
    final index = navigationShell.currentIndex;
    final people = ref.watch(profileListProvider);
    final draft = ref.watch(unfinishedSetupDraftProvider);
    final setup =
        path == '/home' &&
        (people.asData == null ||
            draft.asData == null ||
            people.requireValue.isEmpty ||
            draft.requireValue != null);
    final colors = Theme.of(context).colorScheme;
    final multiplePeople = (people.value?.length ?? 0) > 1;
    if (index == 3 && people.asData != null && !multiplePeople) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && navigationShell.currentIndex == 3) {
          navigationShell.goBranch(0);
        }
      });
    }
    final count = multiplePeople ? 4 : 3;
    final selected = index < count ? index : 0;
    // Phones keep the bottom bar; wider windows move navigation to a side
    // rail. First-run setup shows neither.
    final window = WindowClass.of(context);
    final rail = window.showsRail && !setup;
    final bar = !window.showsRail && !setup;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    Widget navigationFor(int shown) => NavigationBar(
      selectedIndex: shown < count ? shown : selected,
      // The capsule below carries the motion; quiet motion selects at once.
      animationDuration: AppMotion.quiet(context) ? Duration.zero : null,
      onDestinationSelected: _select,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: l.t08_today,
        ),
        NavigationDestination(
          icon: const _MedicationNavigationIcon(),
          selectedIcon: const _MedicationNavigationIcon(selected: true),
          label: l.t08_medications,
        ),
        NavigationDestination(
          icon: const Icon(Icons.article_outlined),
          selectedIcon: const Icon(Icons.article),
          label: l.t08_history,
        ),
        if (multiplePeople)
          NavigationDestination(
            icon: const Icon(Icons.people_outline),
            selectedIcon: const Icon(Icons.people),
            label: l.t08_people,
          ),
      ],
    );
    return Scaffold(
      // A bottom bar hides behind the keyboard while the Scaffold shrinks the
      // body above it, and the body's screens then see no keyboard left to
      // make room for. A rail must not shrink: it keeps its height behind the
      // keyboard and the screens beside it make room themselves, once.
      resizeToAvoidBottomInset: !rail,
      // One row in every window size, with the pane keyed, so resizing or
      // rotating the window moves the rail in and out without rebuilding the
      // tabs (and their navigators) underneath.
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (rail)
            ShellRail(
              selectedIndex: selected,
              multiplePeople: multiplePeople,
              onSelected: _select,
              onSettings: () => context.push(AppPaths.settings),
            ),
          Expanded(
            key: const ValueKey('shell-pane'),
            // The rail sits where a display cutout would otherwise be. The
            // padding is taken from the Scaffold's own view of the screen
            // (the Builder), not the shell's: the shell's still holds the
            // keyboard the Scaffold has already made room for.
            child: Builder(
              builder: (context) => MediaQuery.removePadding(
                context: context,
                removeLeft: rail && !rtl,
                removeRight: rail && rtl,
                child: TabHandOff(index: index, child: navigationShell),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: !bar
          ? null
          : DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  top: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .5),
                  ),
                ),
              ),
              child: NavigationBarTheme(
                data: NavigationBarThemeData(
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  height: 70,
                  indicatorColor: Colors.transparent,
                  labelTextStyle: WidgetStateProperty.resolveWith(
                    (states) =>
                        Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: states.contains(WidgetState.selected)
                              ? colors.primary
                              : colors.onSurfaceVariant,
                          fontWeight: states.contains(WidgetState.selected)
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                  ),
                  iconTheme: WidgetStateProperty.resolveWith(
                    (states) => IconThemeData(
                      size: 28,
                      color: states.contains(WidgetState.selected)
                          ? colors.primary
                          : colors.onSurface,
                    ),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: NavCapsule(index: selected, count: count),
                    ),
                    _DelayedSelection(index: selected, builder: navigationFor),
                  ],
                ),
              ),
            ),
    );
  }
}

/// The side navigation of medium and expanded windows: the Simpastil mark on
/// top, the tabs below it and Settings at the foot. It is the bottom bar's
/// counterpart, with the same destinations in the same order (so branch
/// indexes mean the same thing) and the app's own indicator colours.
///
/// The rail reads its colours from [NavigationRailThemeData]; People appears
/// only when more than one person is shown, as in the bar.
class ShellRail extends StatelessWidget {
  const ShellRail({
    super.key,
    required this.selectedIndex,
    required this.multiplePeople,
    required this.onSelected,
    required this.onSettings,
  });

  final int selectedIndex;
  final bool multiplePeople;
  final ValueChanged<int> onSelected;
  final VoidCallback onSettings;

  /// Below this height the mark makes way and only the open tab keeps its
  /// label, so four tabs and Settings still fit a phone turned sideways.
  static const _roomyHeight = 520.0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final media = MediaQuery.of(context);
    final width = WindowClass.of(context).railWidth;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final cutout = rtl ? media.padding.right : media.padding.left;
    final roomy = media.size.height >= _roomyHeight;
    return SizedBox(
      width: width + cutout,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.navigationRailTheme.backgroundColor ?? colors.surface,
          border: BorderDirectional(
            end: BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
          ),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: cutout,
            top: media.padding.top,
            bottom: media.padding.bottom,
          ),
          // The insets are spent above; the rail must not take them twice.
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            removeLeft: true,
            removeRight: true,
            child: NavigationRail(
              backgroundColor: Colors.transparent,
              minWidth: width,
              selectedIndex: selectedIndex,
              onDestinationSelected: onSelected,
              labelType: roomy
                  ? NavigationRailLabelType.all
                  : NavigationRailLabelType.selected,
              groupAlignment: -1,
              // A short window scrolls the tabs rather than overflow; the
              // mark and Settings keep their places.
              scrollable: true,
              leading: roomy
                  ? const Padding(
                      padding: EdgeInsets.only(top: 12, bottom: 16),
                      child: _RailMark(),
                    )
                  : null,
              trailingAtBottom: true,
              trailing: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 16),
                child: IconButton(
                  key: const ValueKey('shell-rail-settings'),
                  tooltip: l.nav_settings,
                  onPressed: onSettings,
                  iconSize: 24,
                  color: colors.onSurfaceVariant,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(56, 40),
                    shape: const StadiumBorder(),
                  ),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ),
              destinations: [
                NavigationRailDestination(
                  icon: const Icon(Icons.home_outlined),
                  selectedIcon: const Icon(Icons.home),
                  label: _RailLabel(l.t08_today),
                ),
                NavigationRailDestination(
                  icon: const _MedicationNavigationIcon(),
                  selectedIcon: const _MedicationNavigationIcon(selected: true),
                  label: _RailLabel(l.t08_medications),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.article_outlined),
                  selectedIcon: const Icon(Icons.article),
                  label: _RailLabel(l.t08_history),
                ),
                if (multiplePeople)
                  NavigationRailDestination(
                    icon: const Icon(Icons.people_outline),
                    selectedIcon: const Icon(Icons.people),
                    label: _RailLabel(l.t08_people),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tab label that always stays on one line: a long word shrinks a little
/// rather than breaking in the middle ("Medicatio-ns") at large text sizes.
class _RailLabel extends StatelessWidget {
  const _RailLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, maxLines: 1, softWrap: false),
  );
}

/// The Simpastil capsule on a soft tile at the head of the rail. Decorative.
class _RailMark extends StatelessWidget {
  const _RailMark();
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(14),
    ),
    child: const SizedBox.square(
      dimension: 44,
      child: Center(child: CapsuleMark(size: 32)),
    ),
  );
}

/// Reports [index] to [builder] after the capsule has mostly arrived, so the
/// icon and label colour change follows the slide instead of preceding it.
class _DelayedSelection extends StatefulWidget {
  const _DelayedSelection({required this.index, required this.builder});
  final int index;
  final Widget Function(int shown) builder;
  @override
  State<_DelayedSelection> createState() => _DelayedSelectionState();
}

class _DelayedSelectionState extends State<_DelayedSelection> {
  late int _shown = widget.index;
  Timer? _timer;

  @override
  void didUpdateWidget(_DelayedSelection old) {
    super.didUpdateWidget(old);
    if (widget.index == old.index) return;
    _timer?.cancel();
    final delay = AppMotion.duration(context, milliseconds: 170);
    if (delay == Duration.zero) {
      _shown = widget.index;
      return;
    }
    _timer = Timer(delay, () {
      if (mounted) setState(() => _shown = widget.index);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_shown);
}

/// The medication tab's capsule, drawn at the icon theme's size (28 dp unless
/// the navigation says otherwise).
class _MedicationNavigationIcon extends StatelessWidget {
  const _MedicationNavigationIcon({this.selected = false});
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final icons = IconTheme.of(context);
    return CustomPaint(
      size: Size.square(icons.size ?? _MedicationNavigationPainter.nominal),
      painter: _MedicationNavigationPainter(
        icons.color ?? Theme.of(context).colorScheme.onSurface,
        selected,
      ),
    );
  }
}

class _MedicationNavigationPainter extends CustomPainter {
  const _MedicationNavigationPainter(this.color, this.selected);
  final Color color;
  final bool selected;

  /// The size the capsule is drawn for; other sizes scale it.
  static const nominal = 28.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(size.shortestSide / nominal);
    canvas.rotate(.65);
    final capsule = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-6.5, -12, 13, 24),
      const Radius.circular(6.5),
    );
    canvas.drawRRect(capsule, paint);
    if (selected) {
      canvas.save();
      canvas.clipRect(const Rect.fromLTWH(-8, -13, 16, 13));
      canvas.drawRRect(capsule, Paint()..color = color);
      canvas.restore();
    }
    canvas.drawLine(const Offset(-6.5, 0), const Offset(6.5, 0), paint);
  }

  @override
  bool shouldRepaint(_MedicationNavigationPainter oldDelegate) =>
      color != oldDelegate.color || selected != oldDelegate.selected;
}

/// Capsule behind the selected destination. It slides to the new destination
/// with the leading edge arriving first, so it stretches and then settles.
/// Decorative only: excluded from semantics and hit testing.
class NavCapsule extends StatefulWidget {
  const NavCapsule({super.key, required this.index, required this.count});
  final int index;
  final int count;
  @override
  State<NavCapsule> createState() => _NavCapsuleState();
}

class _NavCapsuleState extends State<NavCapsule> {
  static const _width = 64.0;
  static const _height = 34.0;
  static const _top = 6.0;
  int _from = 0;

  @override
  void initState() {
    super.initState();
    _from = widget.index;
  }

  @override
  void didUpdateWidget(NavCapsule old) {
    super.didUpdateWidget(old);
    _from = old.index;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark
        ? const Color(0xFF6E66FA).withValues(alpha: .38)
        : const Color(0xFFD0CFEC);
    final slow = AppMotion.duration(context, milliseconds: 320);
    final fast = AppMotion.duration(context, milliseconds: 220);
    final forward = widget.index >= _from;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, box) {
            final cell = box.maxWidth / widget.count;
            final rtl = Directionality.of(context) == TextDirection.rtl;
            double start(int i) =>
                ((rtl ? widget.count - 1 - i : i) * cell) + (cell - _width) / 2;
            final target = start(widget.index);
            // Leading edge (in travel direction) is the quick one.
            final rightLeads = forward != rtl;
            return TweenAnimationBuilder<double>(
              tween: Tween(end: target),
              duration: rightLeads ? slow : fast,
              curve: Curves.easeInOutCubic,
              builder: (context, left, _) => TweenAnimationBuilder<double>(
                tween: Tween(end: target),
                duration: rightLeads ? fast : slow,
                curve: Curves.easeInOutCubic,
                builder: (context, right, _) {
                  final l = left < right ? left : right;
                  final r = (left > right ? left : right) + _width;
                  return Stack(
                    children: [
                      Positioned(
                        left: l,
                        width: r - l,
                        top: _top,
                        height: _height,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: fill,
                            borderRadius: BorderRadius.circular(_height / 2),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
