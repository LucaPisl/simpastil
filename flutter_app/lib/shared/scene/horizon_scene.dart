import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'ambient_sky.dart';
import 'horizon_model.dart';
import 'horizon_painter.dart';

/// Lets the screen ask where a dose's mark is on the glass right now, so
/// something can fly to it. The scene fills it in while it is mounted.
class HorizonMarkLocator {
  Offset? Function(String id)? _resolve;
  HorizonArc? Function()? _arc;

  /// The mark's centre in global coordinates, or null when the mark is not
  /// on screen (unknown id, header folded away, scene not mounted).
  Offset? globalCenterOf(String id) => _resolve?.call(id);

  /// The day path and the sun as they stand on the glass, or null when the
  /// header is folded away or the scene is not mounted.
  HorizonArc? arc() => _arc?.call();
}

/// Today's day path and sun in global coordinates, read once so something
/// else can carry them on (the shell's hand-off to History).
@immutable
class HorizonArc {
  const HorizonArc({
    required this.points,
    required this.line,
    required this.now,
    this.sun,
    required this.sunColor,
  });

  /// The day path, evenly in time from 00:00 to 24:00; at least two points.
  final List<Offset> points;
  final Color line;

  /// The share of the day the sky stands at (0 for a future day).
  final double now;
  final Offset? sun;
  final Color sunColor;

  /// The point on the path at share [t] of the day.
  Offset at(double t) {
    final f = t.clamp(0.0, 1.0) * (points.length - 1);
    final i = math.min(f.floor(), points.length - 2);
    return Offset.lerp(points[i], points[i + 1], f - i)!;
  }
}

/// The day sky as a widget. It is driven only by events: the entry animation
/// (once, when this State is created), scroll, pull, scrub and celebrate. No
/// controller repeats, so an idle scene costs zero frames.
///
/// [model] was computed for the size this widget is laid out at; callers use
/// a `LayoutBuilder` (or [HorizonScene.live]) to keep the two in step.
class HorizonScene extends StatefulWidget {
  const HorizonScene({
    super.key,
    required this.model,
    this.scroll,
    this.pull,
    this.onMarkTapped,
    this.onScrub,
    this.celebrateId,
    required this.semanticsLabel,
    this.child,
    this.onShowNext,
    this.showNextLabel,
    this.readNextLabel,
    this.breath,
    this.focusedId,
    this.celebrateReach = HorizonPainter.defaultCelebrateReach,
    this.twinkle = 1,
    this.collapse,
    this.ambient,
    this.markLocator,
    this.sweepId,
    this.sunLabel,
    this.onSunScrub,
    this.entryHold,
  });

  /// Lays itself out at the available width and [height] and computes the
  /// model for it.
  static Widget live({
    Key? key,
    required DateTime date,
    required DateTime now,
    required List<HorizonDose> doses,
    required bool highContrast,
    double height = 170,
    Listenable? scroll,
    ValueListenable<double>? pull,
    ValueChanged<String>? onMarkTapped,
    ValueChanged<String>? onScrub,
    String? celebrateId,
    required String semanticsLabel,
    Widget? child,
    VoidCallback? onShowNext,
    String? showNextLabel,
    String? readNextLabel,
    Animation<double>? breath,
    String? focusedId,
    double celebrateReach = HorizonPainter.defaultCelebrateReach,
    double twinkle = 1,
    ValueListenable<double>? collapse,
    AmbientDrift? ambient,
    HorizonMarkLocator? markLocator,
    String? sweepId,
    String? sunLabel,
    ValueChanged<String>? onSunScrub,
    ValueListenable<bool>? entryHold,
    List<Rect> Function(Size scene)? textZonesFor,
  }) {
    return Builder(
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(
            constraints.hasBoundedWidth
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width,
            constraints.hasBoundedHeight ? constraints.maxHeight : height,
          );
          final model = HorizonModel.compute(
            date: date,
            now: now,
            b: Theme.of(context).brightness,
            highContrast: highContrast,
            doses: doses,
            size: size,
            textZones: textZonesFor?.call(size) ?? const [],
          );
          return HorizonScene(
            key: key,
            model: model,
            scroll: scroll,
            pull: pull,
            onMarkTapped: onMarkTapped,
            onScrub: onScrub,
            celebrateId: celebrateId,
            semanticsLabel: semanticsLabel,
            onShowNext: onShowNext,
            showNextLabel: showNextLabel,
            readNextLabel: readNextLabel,
            breath: breath,
            focusedId: focusedId,
            celebrateReach: celebrateReach,
            twinkle: twinkle,
            collapse: collapse,
            ambient: ambient,
            markLocator: markLocator,
            sweepId: sweepId,
            sunLabel: sunLabel,
            onSunScrub: onSunScrub,
            entryHold: entryHold,
            child: child,
          );
        },
      ),
    );
  }

  final HorizonModel model;

  /// A [ScrollController], or a `ValueListenable<double>` of the offset.
  final Listenable? scroll;

  /// Pull-to-refresh progress, 0 at rest, 1 at the trigger threshold.
  final ValueListenable<double>? pull;
  final ValueChanged<String>? onMarkTapped;
  final ValueChanged<String>? onScrub;

  /// Set to a mark id when that dose was just durably recorded.
  final String? celebrateId;
  final String semanticsLabel;
  final Widget? child;
  final VoidCallback? onShowNext;
  final String? showNextLabel;

  /// Names the screen-reader action that says [sunLabel] aloud.
  final String? readNextLabel;

  /// Optional halo breath, 0..1, owned by whoever gates ambient motion.
  final Animation<double>? breath;

  /// The dose the surrounding screen is showing; its mark gets a focus ring.
  /// Null points at the next dose still to record.
  final String? focusedId;

  /// Reach of the celebration ring beyond the mark, in dp.
  final double celebrateReach;

  /// Scale of the celebration twinkle; 0 turns it off.
  final double twinkle;

  /// How far a collapsing header has folded the scene, 0..1: the bodies,
  /// ground, path and marks fade out and stop taking taps by 1.
  final ValueListenable<double>? collapse;

  /// Optional ambient weather (drifting clouds, twinkling stars, settled
  /// glow), drawn over the sky by its own painter. Its owner decides when
  /// it moves; without it the scene is exactly the still sky.
  final AmbientDrift? ambient;

  /// Filled in while mounted so a caller can find a mark on screen.
  final HorizonMarkLocator? markLocator;

  /// Set to a token when the day was just durably settled (every planned
  /// dose recorded): the scene plays its settled sweep once for that token.
  final String? sweepId;

  /// What the sun says when it is tapped ("Next: 14:00 · Ana · Metformin").
  /// Null makes the sun inert.
  final String? sunLabel;

  /// Called with the mark whose time the ghost sun stands at while the sun
  /// is long-pressed and dragged; the screen follows along.
  final ValueChanged<String>? onSunScrub;

  /// While this reads true when the scene first appears, the entry waits:
  /// the path, marks and sun rise only once it turns false. Something
  /// drawing its own way into the scene holds it (setup's finish).
  final ValueListenable<bool>? entryHold;

  @override
  State<HorizonScene> createState() => _HorizonSceneState();
}

class _HorizonSceneState extends State<HorizonScene>
    with TickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final AnimationController _celebrate = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final AnimationController _poke = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  final ValueNotifier<double?> _scrubX = ValueNotifier(null);
  final ValueNotifier<double?> _ghost = ValueNotifier(null);
  String? _ghostMark;
  Timer? _bubbleTimer;

  /// Doses just taken whose star waits in its mark until the receipt's check
  /// lands there (the celebration launches it), so it never shows at home
  /// first. A take with no celebration releases its star after a while.
  final Map<String, Timer> _heldStars = {};
  bool _bubble = false;
  String? _lastScrubbed;
  bool _entryStarted = false;
  AmbientLayout? _ambientLayout;

  @override
  void initState() {
    super.initState();
    _bind(widget.markLocator);
    _reportCare();
  }

  void _bind(HorizonMarkLocator? locator) {
    locator?._resolve = _markCenter;
    locator?._arc = _arcOnGlass;
  }

  void _unbind(HorizonMarkLocator? locator) {
    if (locator?._resolve == _markCenter) locator?._resolve = null;
    if (locator?._arc == _arcOnGlass) locator?._arc = null;
  }

  /// The day path and sun where they are painted, in global coordinates
  /// (the path moves with the ground group, the sun with its own parallax).
  HorizonArc? _arcOnGlass() {
    if ((widget.collapse?.value ?? 0) >= .5) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final model = widget.model;
    final scroll = _scrollOffset().clamp(0.0, 600.0);
    final pull = (widget.pull?.value ?? 0).clamp(0.0, 1.4);
    final ground = -scroll * .4 + pull * 16;
    final sun = _sunCenter();
    final theme = Theme.of(context);
    const steps = 96;
    return HorizonArc(
      points: [
        for (var i = 0; i <= steps; i++)
          box.localToGlobal(model.pathAt(i / steps).translate(0, ground)),
      ],
      line: theme.colorScheme.primary.withValues(alpha: .42),
      now: model.dayProgress,
      sun: sun == null ? null : box.localToGlobal(sun),
      sunColor: HorizonPainter.sunColorOf(
        model,
        dark: theme.brightness == Brightness.dark,
      ),
    );
  }

  /// Where mark [id] is drawn, in global coordinates (the painter shifts the
  /// ground group by the same parallax).
  Offset? _markCenter(String id) {
    if ((widget.collapse?.value ?? 0) >= .5) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    HorizonMark? mark;
    for (final m in widget.model.marks) {
      if (m.id == id) mark = m;
    }
    if (mark == null) return null;
    final scroll = _scrollOffset().clamp(0.0, 600.0);
    final pull = (widget.pull?.value ?? 0).clamp(0.0, 1.4);
    return box.localToGlobal(
      mark.rect.center.translate(0, -scroll * .4 + pull * 16),
    );
  }

  /// Hands the durable care state to the ambient layer (recorded states only
  /// ever come from the stored care day).
  void _reportCare() => widget.ambient?.setCare(
    recorded: widget.model.recorded,
    total: widget.model.total,
  );

  AmbientLayout _layoutFor(HorizonModel model) {
    final cached = _ambientLayout;
    if (cached != null && cached.size == model.size) return cached;
    return _ambientLayout = AmbientLayout.compute(
      size: model.size,
      horizonY: model.horizonY,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final quiet = _quiet(context);
    if (!_entryStarted) {
      _entryStarted = true;
      final hold = widget.entryHold;
      if (quiet) {
        _entry.value = 1;
      } else if (hold != null && hold.value) {
        _held = hold..addListener(_release);
      } else {
        _entry.forward();
      }
    } else if (quiet && (_entry.isAnimating || _held != null)) {
      _letGo();
      _entry.value = 1;
    }
  }

  ValueListenable<bool>? _held;

  void _release() {
    if (_held?.value ?? true) return;
    _letGo();
    _entry.forward();
  }

  void _letGo() {
    _held?.removeListener(_release);
    _held = null;
  }

  void _holdNewStars(HorizonModel old) {
    if (old.marks.isEmpty) return;
    bool taken(HorizonMark m) => m.state == HorizonMarkState.taken;
    final before = {
      for (final m in old.marks)
        if (taken(m)) m.id,
    };
    for (final m in widget.model.marks) {
      if (!taken(m) || before.contains(m.id) || m.id == widget.celebrateId) {
        continue;
      }
      _heldStars[m.id]?.cancel();
      _heldStars[m.id] = Timer(const Duration(milliseconds: 2400), () {
        if (mounted) setState(() => _heldStars.remove(m.id));
      });
    }
  }

  static bool _quiet(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  @override
  void didUpdateWidget(HorizonScene old) {
    super.didUpdateWidget(old);
    if (old.markLocator != widget.markLocator) {
      _unbind(old.markLocator);
      _bind(widget.markLocator);
    }
    if (widget.ambient != null &&
        (widget.ambient != old.ambient ||
            widget.model.recorded != old.model.recorded ||
            widget.model.total != old.model.total)) {
      _reportCare();
    }
    _holdNewStars(old.model);
    final id = widget.celebrateId;
    if (id != null && id != old.celebrateId) {
      _heldStars.remove(id)?.cancel();
      if (!_quiet(context)) _celebrate.forward(from: 0);
    }
    final sweep = widget.sweepId;
    if (sweep != null && sweep != old.sweepId && !_quiet(context)) {
      _sweep.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _letGo();
    _unbind(widget.markLocator);
    _entry.dispose();
    _celebrate.dispose();
    _sweep.dispose();
    _poke.dispose();
    _bubbleTimer?.cancel();
    for (final timer in _heldStars.values) {
      timer.cancel();
    }
    _ghost.dispose();
    _scrubX.dispose();
    super.dispose();
  }

  double _scrollOffset() {
    final s = widget.scroll;
    if (s is ScrollController) {
      return s.hasClients && s.positions.length == 1 ? s.offset : 0;
    }
    if (s is ValueListenable<double>) return s.value;
    return 0;
  }

  /// The sun's centre in this scene's own coordinates, as painted.
  Offset? _sunCenter() {
    final sun = widget.model.sun;
    if (sun == null) return null;
    final scroll = _scrollOffset().clamp(0.0, 600.0);
    final pull = (widget.pull?.value ?? 0).clamp(0.0, 1.4);
    return sun.translate(0, -scroll * .2 + pull * 20);
  }

  void _showBubble() {
    if (widget.sunLabel == null) return;
    _bubbleTimer?.cancel();
    setState(() => _bubble = true);
    _bubbleTimer = Timer(const Duration(milliseconds: 3200), _hideBubble);
  }

  void _readSun() {
    _showBubble();
    SemanticsService.sendAnnouncement(
      View.of(context),
      widget.sunLabel!,
      Directionality.of(context),
    );
  }

  void _hideBubble() {
    _bubbleTimer?.cancel();
    if (mounted && _bubble) setState(() => _bubble = false);
  }

  void _tapSun() {
    if (!_quiet(context)) _poke.forward(from: 0);
    _showBubble();
  }

  void _ghostTo(Offset p) {
    final model = widget.model;
    final share = model.sunShareAtX(p.dx);
    _ghost.value = share;
    final mark = model.nearestMarkByX(p.dx);
    if (mark != null && mark.id != _ghostMark) {
      _ghostMark = mark.id;
      HapticFeedback.selectionClick();
      widget.onSunScrub?.call(mark.id);
    }
  }

  void _scrubTo(Offset p) {
    final model = widget.model;
    _scrubX.value = p.dx.clamp(0.0, model.size.width);
    final mark = model.nearestMarkByX(_scrubX.value!);
    if (mark != null && mark.id != _lastScrubbed) {
      _lastScrubbed = mark.id;
      widget.onScrub?.call(mark.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = widget.model;
    final palette = HorizonPalette.from(
      scheme: theme.colorScheme,
      semantic: theme.extension<AppSemanticColors>()!,
      background: theme.scaffoldBackgroundColor,
      highContrast: model.highContrast,
      label: theme.textTheme.labelSmall,
    );
    final repaint = Listenable.merge([
      ?widget.collapse,
      ?widget.scroll,
      ?widget.pull,
      _entry,
      _celebrate,
      _sweep,
      _poke,
      _ghost,
      _scrubX,
      ?widget.breath,
    ]);
    // The backdrop only reacts to scroll, pull and the entry, so a sweep,
    // poke or ghost frame never re-records the sky gradient.
    final backdropRepaint = Listenable.merge([
      ?widget.collapse,
      ?widget.scroll,
      ?widget.pull,
      _entry,
    ]);
    HorizonPainter painterFor(HorizonLayer layer) => HorizonPainter(
      model: model,
      palette: palette,
      scrollOffset: widget.scroll == null ? null : _scrollOffset,
      pull: widget.pull,
      entry: _entry,
      celebrateAnimation: _celebrate,
      celebrateId: widget.celebrateId,
      heldStars: {..._heldStars.keys},
      scrubX: _scrubX,
      breath: widget.breath,
      focusedId: widget.focusedId,
      celebrateReach: widget.celebrateReach,
      twinkle: widget.twinkle,
      collapse: widget.collapse,
      sweepAnimation: _sweep,
      sweepId: widget.sweepId,
      pokeAnimation: _poke,
      ghostShare: _ghost,
      layer: layer,
      repaint: layer == HorizonLayer.backdrop ? backdropRepaint : repaint,
    );
    // With ambient weather the scene paints in three steps: the sky, then the
    // clouds (the child), then the bodies, path and marks. Clouds therefore
    // pass behind the sun and never over a dose mark.
    final layered = widget.ambient != null;
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (widget.onShowNext != null && widget.showNextLabel != null)
        CustomSemanticsAction(label: widget.showNextLabel!): widget.onShowNext!,
      // The sun's line is otherwise touch-only: this puts it in reach of a
      // screen reader, which reads it out as well as showing the bubble.
      if (widget.sunLabel != null && widget.readNextLabel != null)
        CustomSemanticsAction(label: widget.readNextLabel!): _readSun,
    };
    return ClipRect(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: Semantics(
              container: true,
              label: widget.semanticsLabel,
              customSemanticsActions: actions.isEmpty ? null : actions,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) {
                  if ((widget.collapse?.value ?? 0) >= .5) return;
                  // Dose marks win where they overlap the sun.
                  final mark = model.nearestMark(d.localPosition);
                  if (mark != null) {
                    widget.onMarkTapped?.call(mark.id);
                  }
                },
                onHorizontalDragStart: widget.onScrub == null
                    ? null
                    : (d) {
                        _lastScrubbed = null;
                        _scrubTo(d.localPosition);
                      },
                onHorizontalDragUpdate: widget.onScrub == null
                    ? null
                    : (d) => _scrubTo(d.localPosition),
                onHorizontalDragEnd: (_) => _scrubX.value = null,
                onHorizontalDragCancel: () => _scrubX.value = null,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: painterFor(
                      layered ? HorizonLayer.backdrop : HorizonLayer.all,
                    ),
                    foregroundPainter: layered
                        ? painterFor(HorizonLayer.bodies)
                        : null,
                    size: model.size,
                    // The ambient layer has its own boundary, so a drift
                    // frame re-records only the clouds, not the scene. It
                    // paints after the backdrop and before the bodies.
                    child: widget.ambient == null
                        ? null
                        : RepaintBoundary(
                            child: CustomPaint(
                              size: model.size,
                              painter: AmbientSkyPainter(
                                model: model,
                                layout: _layoutFor(model),
                                drift: widget.ambient!,
                                dark: theme.brightness == Brightness.dark,
                                collapse: widget.collapse,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.child != null) widget.child!,
          if (widget.sunLabel != null) _sunTarget(),
          if (widget.sunLabel != null) _bubbleLayer(context),
        ],
      ),
    );
  }

  /// A 56 dp target that follows the sun. Its long press scrubs the ghost sun,
  /// so a held tap anywhere else (on a dose mark, say) never reaches the
  /// long-press recognizer and can neither be swallowed nor block scrolling.
  Widget _sunTarget() {
    final listenable = Listenable.merge([
      ?widget.scroll,
      ?widget.pull,
      ?widget.collapse,
    ]);
    const half = 28.0;
    return Positioned.fill(
      child: ListenableBuilder(
        listenable: listenable,
        builder: (context, _) {
          final c = _sunCenter();
          if (c == null || (widget.collapse?.value ?? 0) >= .5) {
            // The target going away mid-press disposes its recognizer with
            // no cancel callback, so clear a lingering ghost here.
            if (_ghost.value != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _ghost.value = null;
              });
            }
            return const SizedBox.shrink();
          }
          return Stack(
            children: [
              Positioned(
                left: c.dx - half,
                top: c.dy - half,
                width: half * 2,
                height: half * 2,
                child: ExcludeSemantics(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (d) {
                      final p =
                          d.localPosition + Offset(c.dx - half, c.dy - half);
                      // Dose marks win where they overlap the sun.
                      final mark = widget.model.nearestMark(p);
                      if (mark != null) {
                        widget.onMarkTapped?.call(mark.id);
                      } else {
                        _tapSun();
                      }
                    },
                    onLongPressStart: widget.onSunScrub == null
                        ? null
                        : (d) {
                            _ghostMark = null;
                            _hideBubble();
                            HapticFeedback.selectionClick();
                            _ghostTo(
                              d.localPosition +
                                  Offset(c.dx - half, c.dy - half),
                            );
                          },
                    onLongPressMoveUpdate: widget.onSunScrub == null
                        ? null
                        : (d) {
                            if (_ghost.value != null) {
                              _ghostTo(
                                d.localPosition +
                                    Offset(c.dx - half, c.dy - half),
                              );
                            }
                          },
                    onLongPressEnd: (_) => _ghost.value = null,
                    onLongPressCancel: () => _ghost.value = null,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The line the sun says when tapped, drawn just above (or, near the top,
  /// below) the disc. It never takes touches and fades out by itself.
  Widget _bubbleLayer(BuildContext context) {
    // Rebuilds with scroll and pull so the bubble stays with the sun.
    return Positioned.fill(
      child: ListenableBuilder(
        listenable: Listenable.merge([
          ?widget.scroll,
          ?widget.pull,
          ?widget.collapse,
        ]),
        builder: (context, _) {
          // A folded header has no sun to speak: the bubble goes with it.
          if ((widget.collapse?.value ?? 0) >= .5) {
            if (_bubble) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _hideBubble(),
              );
            }
            return const SizedBox.shrink();
          }
          return Stack(children: [_bubbleAt(context)]);
        },
      ),
    );
  }

  Widget _bubbleAt(BuildContext context) {
    final c = _sunCenter();
    final label = widget.sunLabel;
    if (c == null || label == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final width = widget.model.size.width;
    final above = c.dy > 62;
    return Positioned(
      left: 16,
      right: 16,
      top: above ? null : c.dy + 22,
      bottom: above ? widget.model.size.height - c.dy + 22 : null,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment(((c.dx / width) * 2 - 1).clamp(-.8, .8), 0),
          child: AnimatedOpacity(
            opacity: _bubble ? 1 : 0,
            duration: _quiet(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: Semantics(
              liveRegion: _bubble,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: .94),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant,
                    width: .8,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
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
}
