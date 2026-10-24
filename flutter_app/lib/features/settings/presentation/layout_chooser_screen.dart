import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_follow_widgets.dart';
import '../../../core/medication/reviewed_time_zone.dart';
import '../../../core/storage/layout_family_preference.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/scene/scene_clock.dart';
import '../../dashboard/today_layout/layout_preview.dart';
import '../../dashboard/today_layout/today_layouts.dart';
import 'settings_pane.dart';

/// Opens the layout chooser over the current route.
Future<void> openLayoutChooser(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const LayoutChooserScreen()));

/// Six layout cards with live miniatures of the real layout widgets over the
/// person's own day, or an example day when nothing is planned today. A card opens a full preview; only its explicit Apply
/// changes Today, and Cancel leaves everything as it was. Person, date,
/// drafts and colours are independent of this device-local choice.
class LayoutChooserScreen extends ConsumerStatefulWidget {
  const LayoutChooserScreen({super.key});
  @override
  ConsumerState<LayoutChooserScreen> createState() =>
      _LayoutChooserScreenState();
}

class _LayoutChooserScreenState extends ConsumerState<LayoutChooserScreen> {
  String? _message;

  Future<void> _preview(LayoutFamily family) async {
    final quiet = AppMotion.quiet(context);
    // The card's miniature opens into the full preview; the page itself
    // only fades, so the layout's flight is the motion that is seen.
    final applied = await Navigator.of(context).push<bool>(
      PageRouteBuilder(
        transitionDuration: quiet
            ? Duration.zero
            : const Duration(milliseconds: 520),
        reverseTransitionDuration: quiet
            ? Duration.zero
            : const Duration(milliseconds: 420),
        pageBuilder: (_, _, _) => LayoutPreviewScreen(family: family),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Interval(0, .6, curve: Curves.easeOut),
          ),
          child: child,
        ),
      ),
    );
    if (applied == true && mounted) {
      final l = AppLocalizations.of(context);
      setState(() => _message = l.lay_applied(layoutFamilyName(l, family)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final current = effectiveLayoutFamily(ref.watch(layoutFamilyProvider));
    final now = ref.watch(sceneClockProvider)();
    final own = ref.watch(layoutPreviewOwnDayProvider);
    final zone = ref.watch(deviceTimeZoneProvider).value ?? 'UTC';
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    return Scaffold(
      appBar: SettingsPaneScope.isEmbedded(context)
          ? settingsDetailAppBar(context, l.t15_layout)
          : AppBar(title: Text(l.t15_layout)),
      body: SafeArea(
        top: false,
        child: ContentListView(
          key: const ValueKey('layout-chooser'),
          maxWidth: settingsContentWidth(context),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            Text(
              l.lay_intro,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const DeviceOnlyLabel('todayLayout'),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _message!,
                    key: const ValueKey('layout-applied'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = large
                    ? 1
                    : constraints.maxWidth >= 600
                    ? 3
                    : 2;
                const gap = 12.0;
                Widget card(LayoutFamily family, {required bool fill}) =>
                    _LayoutCard(
                      family: family,
                      now: now,
                      own: own,
                      zone: zone,
                      current: family == current,
                      wide: columns == 1,
                      fill: fill,
                      onTap: () => _preview(family),
                    );
                if (columns == 1) {
                  return Column(
                    children: [
                      for (final family in LayoutFamily.values) ...[
                        if (family != LayoutFamily.values.first)
                          const SizedBox(height: gap),
                        card(family, fill: false),
                      ],
                    ],
                  );
                }
                // Cards share their row's height, with the status and Preview
                // line on one baseline at the foot, however long a
                // description runs.
                const all = LayoutFamily.values;
                return Column(
                  children: [
                    for (var start = 0; start < all.length; start += columns)
                      Padding(
                        padding: EdgeInsets.only(top: start == 0 ? 0 : gap),
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < columns; i++) ...[
                                if (i > 0) const SizedBox(width: gap),
                                Expanded(
                                  child: start + i < all.length
                                      ? card(all[start + i], fill: true)
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Logical size the miniatures are laid out at before scaling down.
const _miniature = Size(380, 600);

class _LayoutCard extends StatelessWidget {
  const _LayoutCard({
    required this.family,
    required this.now,
    required this.own,
    required this.zone,
    required this.current,
    required this.wide,
    required this.fill,
    required this.onTap,
  });
  final LayoutFamily family;
  final DateTime now;
  final LayoutPreviewDay? own;
  final String zone;
  final bool current, wide;

  /// The card stretches to its row: the status line sits at its foot.
  final bool fill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final available = layoutFamilyAvailable(family);
    final name = layoutFamilyName(l, family);
    final status = current
        ? l.lay_inUse
        : available
        ? null
        : l.lay_notReady;
    final miniature = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: AspectRatio(
          key: const ValueKey('layout-miniature-frame'),
          aspectRatio: _miniature.width / _miniature.height,
          child: available
              ? Hero(
                  tag: layoutPreviewHeroTag(family),
                  flightShuttleBuilder: _flight(family, now, own, zone),
                  child: _Miniature(
                    family: family,
                    now: now,
                    own: own,
                    zone: zone,
                  ),
                )
              : _Unbuilt(family: family),
        ),
      ),
    );
    // One button per card: its name, what it does and its state, read as
    // sentences, and a tap action that opens the preview.
    return Semantics(
      button: true,
      selected: current,
      label: layoutCardLabel([
        name,
        layoutFamilyDescription(l, family),
        ?status,
      ]),
      onTap: onTap,
      onTapHint: l.lay_preview,
      excludeSemantics: true,
      child: Pressable(
        radius: BorderRadius.circular(18),
        child: TweenAnimationBuilder<double>(
          // The ring moves to the card that was just chosen.
          tween: Tween(end: current ? 1 : 0),
          duration: AppMotion.duration(context, milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, selected, child) => Material(
            color: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                color: Color.lerp(
                  colors.outlineVariant,
                  colors.primary,
                  selected,
                )!,
                width: 1 + selected,
              ),
            ),
            child: child,
          ),
          child: InkWell(
            key: ValueKey('layout-card-${family.name}'),
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // At large text the card spans the width; the preview keeps
                  // its portrait shape and scales down whole.
                  wide
                      ? Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 240),
                            child: miniature,
                          ),
                        )
                      : miniature,
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(layoutFamilyIcon(family), size: 20),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (fill)
                    Expanded(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          layoutFamilyDescription(l, family),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    )
                  else
                    Text(
                      layoutFamilyDescription(l, family),
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (status != null)
                        AnimatedSwitcher(
                          duration: AppMotion.duration(
                            context,
                            milliseconds: 320,
                          ),
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(
                                scale: CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutBack,
                                ),
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              ),
                          child: Container(
                            key: ValueKey(status),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: current
                                  ? colors.primaryContainer
                                  : colors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (current) ...[
                                  Icon(
                                    Icons.check,
                                    size: 16,
                                    color: colors.onPrimaryContainer,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Flexible(
                                  child: Text(
                                    status,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: current
                                              ? colors.onPrimaryContainer
                                              : colors.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Text(
                        l.lay_preview,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.primary,
                        ),
                      ),
                    ],
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

/// A card's spoken label: its parts as sentences, each ending in one period
/// however its own text ends.
@visibleForTesting
String layoutCardLabel(List<String> parts) => [
  for (final part in parts)
    part.endsWith('.') ? part.substring(0, part.length - 1) : part,
].join('. ');

/// Shared by a chooser card's miniature and its full preview.
String layoutPreviewHeroTag(LayoutFamily family) =>
    'layout-preview-${family.name}';

/// The miniature grows into the full preview and shrinks back into its card.
///
/// The flight lays the real layout out once, at the preview's own width and
/// text size, and only moves and scales it: a margin that matches the
/// miniature's padding melts away as it lands. Re-laying it out every frame
/// would restart the layout's own size animations mid-flight.
HeroFlightShuttleBuilder _flight(
  LayoutFamily family,
  DateTime now,
  LayoutPreviewDay? own,
  String zone,
) => (flightContext, animation, direction, fromContext, toContext) {
  final previewContext = direction == HeroFlightDirection.push
      ? toContext
      : fromContext;
  final width =
      (previewContext.findRenderObject() as RenderBox?)?.size.width ??
      _miniature.width;
  final media = MediaQuery.of(previewContext);
  final background = Theme.of(previewContext).scaffoldBackgroundColor;
  final layout = IgnorePointer(
    child: ExcludeSemantics(
      child: TickerMode(
        enabled: false,
        child: MediaQuery(
          data: media.copyWith(disableAnimations: true),
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: width,
              child: LayoutPreview(
                family: family,
                now: now,
                own: own,
                zone: zone,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // In the card the layout sits inside a 16 of 380 margin.
  const margin = 16 / 380;
  return LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: animation,
      child: layout,
      builder: (context, child) {
        final t = animation.value;
        final inset = width * margin * (1 - t);
        final frame = width + inset * 2;
        return ClipRRect(
          borderRadius: BorderRadius.circular(12 * (1 - t)),
          child: ColoredBox(
            color: background,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: frame,
              maxWidth: frame,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Transform.scale(
                scale: constraints.maxWidth / frame,
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(inset, inset, inset, 0),
                  child: Align(alignment: Alignment.topLeft, child: child),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
};

/// The real layout widget at a fixed phone size, scaled down, frozen (no
/// tickers, no clock), unreachable by touch and silent to screen readers.
class _Miniature extends StatelessWidget {
  const _Miniature({
    required this.family,
    required this.now,
    required this.own,
    required this.zone,
  });
  final LayoutFamily family;
  final DateTime now;
  final LayoutPreviewDay? own;
  final String zone;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: TickerMode(
        enabled: false,
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.noScaling, disableAnimations: true),
          child: FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.topCenter,
            child: SizedBox.fromSize(
              size: _miniature,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: LayoutPreview(
                      family: family,
                      now: now,
                      own: own,
                      zone: zone,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Unbuilt extends StatelessWidget {
  const _Unbuilt({required this.family});
  final LayoutFamily family;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(color: colors.surfaceContainerLow),
        child: Center(
          child: Icon(
            layoutFamilyIcon(family),
            size: 40,
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Full-size preview of one layout over the same day as its card, with explicit
/// Cancel and Apply. Pops `true` only after the choice is durably saved.
class LayoutPreviewScreen extends ConsumerStatefulWidget {
  const LayoutPreviewScreen({super.key, required this.family});
  final LayoutFamily family;
  @override
  ConsumerState<LayoutPreviewScreen> createState() =>
      _LayoutPreviewScreenState();
}

class _LayoutPreviewScreenState extends ConsumerState<LayoutPreviewScreen> {
  bool _saving = false;
  bool _applied = false;
  String? _error;

  Future<void> _apply() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(layoutFamilyProvider.notifier).apply(widget.family);
      if (!mounted) return;
      // A beat on the confirmed choice before the preview folds back into
      // its card.
      if (!AppMotion.quiet(context)) {
        setState(() => _applied = true);
        await Future<void>.delayed(const Duration(milliseconds: 560));
        if (!mounted) return;
      }
      Navigator.of(context).pop(true);
    } on Object {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).lay_saveError);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final family = widget.family;
    final name = layoutFamilyName(l, family);
    final available = layoutFamilyAvailable(family);
    final current =
        effectiveLayoutFamily(ref.watch(layoutFamilyProvider)) == family;
    final now = ref.watch(sceneClockProvider)();
    final own = ref.watch(layoutPreviewOwnDayProvider);
    final zone = ref.watch(deviceTimeZoneProvider).value ?? 'UTC';
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: Text(l.lay_previewOf(name))),
        body: SafeArea(
          top: false,
          child: ContentListView(
            key: const ValueKey('layout-preview'),
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
              Text(
                layoutFamilyDescription(l, family),
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          !available
                              ? l.lay_notReadyBody
                              : own != null
                              ? l.lay_previewYours
                              : l.lay_previewNotice,
                          key: const ValueKey('layout-preview-notice'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (available)
                Hero(
                  tag: layoutPreviewHeroTag(family),
                  flightShuttleBuilder: _flight(family, now, own, zone),
                  child: LayoutPreview(
                    family: family,
                    now: now,
                    own: own,
                    zone: zone,
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            // The buttons keep the page's column, not the whole window.
            child: ContentFrame(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final cancel = OutlinedButton(
                          key: const ValueKey('layout-cancel'),
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop(false),
                          child: Text(l.shared_cancel),
                        );
                        final colors = theme.colorScheme;
                        final apply = FilledButton(
                          key: const ValueKey('layout-apply'),
                          onPressed: !available || current || _saving
                              ? null
                              : _apply,
                          // Just applied, the button keeps its colour and
                          // turns into the confirmation.
                          style: _applied
                              ? FilledButton.styleFrom(
                                  disabledBackgroundColor: colors.primary,
                                  disabledForegroundColor: colors.onPrimary,
                                )
                              : null,
                          child: AnimatedSwitcher(
                            duration: AppMotion.duration(
                              context,
                              milliseconds: 260,
                            ),
                            transitionBuilder: (child, animation) =>
                                ScaleTransition(
                                  scale: Tween(begin: .8, end: 1.0).animate(
                                    CurvedAnimation(
                                      parent: animation,
                                      curve: Curves.easeOutBack,
                                    ),
                                  ),
                                  child: FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                                ),
                            child: _applied
                                ? Row(
                                    key: const ValueKey('layout-applied-check'),
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.check_rounded, size: 20),
                                      const SizedBox(width: 6),
                                      Flexible(child: Text(l.lay_inUse)),
                                    ],
                                  )
                                : Text(
                                    key: ValueKey(
                                      _saving
                                          ? 'saving'
                                          : current
                                          ? 'current'
                                          : 'use',
                                    ),
                                    _saving
                                        ? l.t08_saving
                                        : current
                                        ? l.lay_inUse
                                        : available
                                        ? l.lay_use(name)
                                        : l.lay_notReady,
                                  ),
                          ),
                        );
                        // Side by side only while the longer label fits its
                        // half on one line; otherwise the buttons stack.
                        final scaler = MediaQuery.textScalerOf(context);
                        final half = (constraints.maxWidth - 12) / 2 - 48;
                        final widest = [l.shared_cancel, l.lay_use(name)]
                            .map((label) {
                              final painter = TextPainter(
                                text: TextSpan(
                                  text: label,
                                  style: theme.textTheme.labelLarge,
                                ),
                                textDirection: Directionality.of(context),
                                textScaler: scaler,
                                maxLines: 1,
                              )..layout();
                              final width = painter.width;
                              painter.dispose();
                              return width;
                            })
                            .reduce((a, b) => a > b ? a : b);
                        if (widest > half || constraints.maxWidth < 330) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              apply,
                              const SizedBox(height: 8),
                              cancel,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: cancel),
                            const SizedBox(width: 12),
                            Expanded(child: apply),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
