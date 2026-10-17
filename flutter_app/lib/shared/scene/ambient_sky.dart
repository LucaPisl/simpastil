import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../motion/ambient_motion.dart';
import 'horizon_model.dart';

/// The ambient weather of the Today sky: a few soft clouds that drift, and
/// at night a handful of stars that twinkle.
///
/// The mood follows the time of day and, gently, the day's care: clouds sit
/// at their time-of-day amount while nothing is recorded, part and thin as
/// doses are recorded, and clear into a settled glow once everything planned
/// is recorded. Nothing ever gets heavier than the time-of-day base, so a
/// late or missed dose never darkens the sky. Only recorded states that come
/// from the durable care day reach this layer, so it never runs ahead of a
/// receipt.
@immutable
class AmbientMood {
  const AmbientMood({required this.cover, required this.base});

  /// How much of the time-of-day cloud is showing, 0 clear .. [base].
  final double cover;

  /// Cloud carried by the time of day alone: fullest by day, a little less
  /// at dawn and dusk, thin wisps at night.
  final double base;

  /// Share used when nothing is planned for the day: a light, neutral sky.
  static const double neutralShare = .35;

  /// Recorded share of the day, or null when nothing is planned.
  static double? careShare(int recorded, int total) =>
      total <= 0 ? null : (recorded / total).clamp(0.0, 1.0);

  static double baseFor({required double dayness, required double starAlpha}) {
    final twilight = (1 - dayness - starAlpha).clamp(0.0, 1.0);
    return (dayness + twilight * .85 + starAlpha * .5).clamp(0.0, 1.0);
  }

  factory AmbientMood.of({
    required double dayness,
    required double starAlpha,
    required double? share,
  }) {
    final base = baseFor(dayness: dayness, starAlpha: starAlpha);
    final s = (share ?? neutralShare).clamp(0.0, 1.0);
    return AmbientMood(cover: base * (1 - s), base: base);
  }
}

/// The outline of a cloud's puffs merged into one shape, so the light-mode
/// rim follows its silhouette and shows no circles inside it. Built once per
/// cloud, on first paint.
final Expando<Path> _cloudRims = Expando<Path>('cloudRim');

Path _rimOf(AmbientCloud cloud) => _cloudRims[cloud] ??= cloud.puffs
    .map((r) => Path()..addOval(r))
    .reduce((a, b) => Path.combine(PathOperation.union, a, b));

/// One soft cloud: a few overlapping puffs around a centre, precomputed once
/// per scene size. Offsets and sizes are relative to the cloud centre.
@immutable
class AmbientCloud {
  const AmbientCloud({
    required this.x0,
    required this.y,
    required this.width,
    required this.speed,
    required this.puffs,
    required this.side,
  }) : ovals = const [];

  AmbientCloud._withOvals(AmbientCloud c, this.ovals)
    : x0 = c.x0,
      y = c.y,
      width = c.width,
      speed = c.speed,
      puffs = c.puffs,
      side = c.side;

  /// Shrinking passes each puff is drawn in: together they make a soft core
  /// and a faint rim without any blur.
  static const passes = <double>[1, .8, .58];

  /// [puffs] at every pass, precomputed so painting allocates nothing.
  final List<Rect> ovals;

  AmbientCloud withOvals() => AmbientCloud._withOvals(
    this,
    List.unmodifiable([
      for (final pass in passes)
        for (final puff in puffs)
          Rect.fromCenter(
            center: puff.center * pass,
            width: puff.width * pass,
            height: puff.height * pass,
          ),
    ]),
  );

  /// Start position (centre) at drift time 0.
  final double x0;
  final double y;
  final double width;

  /// Drift in dp per drift-second (always rightward, like a steady breeze).
  final double speed;
  final List<Rect> puffs;

  /// -1 left of the sun, 1 right of it: the way the cloud parts.
  final double side;

  /// Centre x at drift time [t], wrapped so a cloud leaving on the right
  /// re-enters on the left.
  double xAt(double t, double sceneWidth, {double part = 0}) {
    final span = sceneWidth + width * 1.2;
    final raw = x0 + speed * t + side * part + width * .6;
    final wrapped = raw % span;
    return (wrapped < 0 ? wrapped + span : wrapped) - width * .6;
  }
}

@immutable
class AmbientStar {
  const AmbientStar({
    required this.position,
    required this.radius,
    required this.period,
    required this.phase,
    required this.sparkle,
  });

  final Offset position;
  final double radius;

  /// Twinkle period in drift-seconds.
  final double period;
  final double phase;
  final bool sparkle;

  /// 0..1 brightness at drift time [t].
  double twinkleAt(double t) =>
      .5 + .5 * math.sin(2 * math.pi * (t / period + phase));
}

/// Geometry of the ambient layer for one scene size. Deterministic for a
/// given [seed]: the same size and seed always yield the same sky.
@immutable
class AmbientLayout {
  const AmbientLayout._(this.size, this.clouds, this.stars, this.seed);

  static const cloudCount = 5;
  static const starCount = 7;

  factory AmbientLayout.compute({
    required Size size,
    required double horizonY,
    int seed = 23,
  }) {
    final rng = _Lcg(seed);
    final w = size.width;
    final top = horizonY * .14, bottom = horizonY * .52;
    final clouds = <AmbientCloud>[];
    for (var i = 0; i < cloudCount; i++) {
      // Spread the start positions evenly, then jitter, so the sky never
      // opens on a pile-up.
      final x0 = (i + .2 + rng.next() * .6) / cloudCount * w;
      final y = top + rng.next() * (bottom - top);
      final cw = 70 + rng.next() * 60;
      final ch = cw * (.26 + rng.next() * .08);
      final puffs = <Rect>[
        // A flat base and three or four rounded puffs along its top.
        Rect.fromCenter(
          center: Offset(0, ch * .12),
          width: cw,
          height: ch * .55,
        ),
      ];
      final count = 3 + (rng.next() * 2).floor();
      for (var p = 0; p < count; p++) {
        final u = (p + .5) / count - .5;
        final r = ch * (.32 + rng.next() * .22) * (1 - u.abs() * .7);
        puffs.add(
          Rect.fromCircle(
            center: Offset(u * cw * .78, -ch * .05 - r * .35),
            radius: r,
          ),
        );
      }
      clouds.add(
        AmbientCloud(
          x0: x0,
          y: y,
          width: cw,
          speed: 3.5 + rng.next() * 3,
          puffs: List.unmodifiable(puffs),
          side: i.isEven ? -1 : 1,
        ).withOvals(),
      );
    }
    final stars = <AmbientStar>[
      for (var i = 0; i < starCount; i++)
        AmbientStar(
          position: Offset(
            (i + .15 + rng.next() * .7) / starCount * w,
            horizonY * (.06 + rng.next() * .5),
          ),
          radius: 1 + rng.next() * .6,
          period: 3.5 + rng.next() * 3,
          phase: rng.next(),
          sparkle: i % 3 == 0,
        ),
    ];
    return AmbientLayout._(
      size,
      List.unmodifiable(clouds),
      List.unmodifiable(stars),
      seed,
    );
  }

  final Size size;
  final List<AmbientCloud> clouds;
  final List<AmbientStar> stars;
  final int seed;

  /// How visible cloud [index] is at [cover] (0..1): clouds thin out one by
  /// one, the last one going last, instead of all fading together.
  static double cloudWeight(int index, double cover) =>
      (cover * (cloudCount + 1) - index).clamp(0.0, 1.0);

  @override
  bool operator ==(Object other) =>
      other is AmbientLayout && other.size == size && other.seed == seed;

  @override
  int get hashCode => Object.hash(size, seed);
}

/// The single controller behind the ambient layer.
///
/// It runs on a [Timer], not a vsync ticker: a ticker would request a frame
/// on every vsync (60 fps), while the drift needs far less. Each tick steps
/// drift time by a fixed [frameInterval] (about 15 fps), so motion is
/// deterministic in tests and slows gracefully under load.
///
/// It also rests: a drift window of [windowLength] (speed eases in and out,
/// so the stop is not visible) is followed by [restLength] with no frames at
/// all, and after [idleLimit] without a touch it stops until [wake]. When
/// [active] is false (reduced motion, background, hidden tab, covered route,
/// header scrolled away) it stops at once and the still composition is
/// painted.
class AmbientDrift extends ChangeNotifier {
  AmbientDrift();

  static const frameInterval = Duration(milliseconds: 66);
  static const windowLength = Duration(seconds: 20);
  static const restLength = Duration(seconds: 25);
  static const idleLimit = Duration(minutes: 3);

  /// Easing time constant for the care mood, in seconds.
  static const double easeSeconds = 1.6;

  double _time = 0;
  double? _share;
  double? _shareTarget;
  bool _hasTarget = false;
  double _glow = 0;
  double _glowTarget = 0;

  bool _active = false;
  bool _disposed = false;
  Timer? _frame;
  Timer? _rest;
  double _windowElapsed = 0;
  double _sinceWake = 0;

  /// Ticks run so far; tests use it to count frames.
  @visibleForTesting
  int debugTicks = 0;

  /// Drift time in seconds: only advances inside a drift window.
  double get time => _time;

  /// Eased recorded share of the day, or null when nothing is planned.
  double? get share => _share;

  /// Eased settled glow, 0..1.
  double get glow => _glow;

  bool get active => _active;

  /// True while frames are being produced.
  bool get isDrifting => _frame != null;

  /// True while waiting between drift windows.
  bool get isResting => _rest != null;

  set active(bool value) {
    if (value == _active || _disposed) return;
    _active = value;
    if (value) {
      _sinceWake = 0;
      _startWindow();
    } else {
      _stopTimers();
      if (_snapToTargets()) notifyListeners();
    }
  }

  /// A touch: keeps the sky drifting for another [idleLimit].
  void wake() {
    _sinceWake = 0;
    if (_active && _frame == null && _rest == null) _startWindow();
  }

  /// The care state the scene is drawn for. While drifting the mood eases
  /// toward it; otherwise it is applied at once.
  void setCare({required int recorded, required int total}) {
    final share = AmbientMood.careShare(recorded, total);
    final glow = total > 0 && recorded >= total ? 1.0 : 0.0;
    if (_hasTarget && share == _shareTarget && glow == _glowTarget) return;
    final first = !_hasTarget;
    _hasTarget = true;
    _shareTarget = share;
    _glowTarget = glow;
    if (first || !_active || _shareTarget == null || _share == null) {
      if (_snapToTargets()) notifyListeners();
      return;
    }
    // A durable recording is an event: the sky answers it now, even mid-rest.
    if (_frame == null) {
      _rest?.cancel();
      _rest = null;
      _startWindow();
    }
  }

  bool _snapToTargets() {
    final changed = _share != _shareTarget || _glow != _glowTarget;
    _share = _shareTarget;
    _glow = _glowTarget;
    return changed;
  }

  void _startWindow() {
    if (_disposed || !_active) return;
    _rest?.cancel();
    _rest = null;
    _windowElapsed = 0;
    _frame ??= Timer.periodic(frameInterval, (_) => _tick());
  }

  void _tick() {
    if (_disposed || !_active) return;
    debugTicks++;
    final dt = frameInterval.inMicroseconds / 1e6;
    final window = windowLength.inMicroseconds / 1e6;
    _windowElapsed += dt;
    _sinceWake += dt;
    final u = (_windowElapsed / window).clamp(0.0, 1.0);
    final envelope = math.pow(math.sin(math.pi * u), 2).toDouble();
    _time += dt * envelope;
    final k = 1 - math.exp(-dt / easeSeconds);
    final s = _share, st = _shareTarget;
    if (s != null && st != null) {
      _share = (st - s).abs() < .002 ? st : s + (st - s) * k;
    }
    _glow = (_glowTarget - _glow).abs() < .002
        ? _glowTarget
        : _glow + (_glowTarget - _glow) * k;
    notifyListeners();
    final settled = _share == _shareTarget && _glow == _glowTarget;
    if (u >= 1 && settled) {
      _frame?.cancel();
      _frame = null;
      if (_sinceWake >= idleLimit.inSeconds) return;
      _rest = Timer(restLength, () {
        _rest = null;
        _sinceWake += restLength.inMicroseconds / 1e6;
        if (_sinceWake < idleLimit.inSeconds) _startWindow();
      });
    }
  }

  void _stopTimers() {
    _frame?.cancel();
    _frame = null;
    _rest?.cancel();
    _rest = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    super.dispose();
  }
}

/// Turns [drift] on only while the ambient layer can be seen: ambient motion
/// is allowed ([AmbientMotion.of]: opted in, app resumed, tab not hidden,
/// no dialog or sheet on the root navigator, no reduced motion), the route is the current one (no sheet or page on
/// top), [enabled] holds, and the header is not scrolled fully away.
class AmbientSkyDriver extends StatefulWidget {
  const AmbientSkyDriver({
    super.key,
    required this.drift,
    required this.child,
    this.enabled = true,
    this.collapse,
  });

  final AmbientDrift drift;
  final bool enabled;
  final ValueListenable<double>? collapse;
  final Widget child;

  @override
  State<AmbientSkyDriver> createState() => _AmbientSkyDriverState();
}

class _AmbientSkyDriverState extends State<AmbientSkyDriver> {
  bool _allowed = false;

  @override
  void initState() {
    super.initState();
    widget.collapse?.addListener(_sync);
  }

  @override
  void didUpdateWidget(AmbientSkyDriver old) {
    super.didUpdateWidget(old);
    if (old.collapse != widget.collapse) {
      old.collapse?.removeListener(_sync);
      widget.collapse?.addListener(_sync);
    }
  }

  @override
  void dispose() {
    widget.collapse?.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final folded = (widget.collapse?.value ?? 0) >= 1;
    widget.drift.active = _allowed && !folded;
  }

  @override
  Widget build(BuildContext context) {
    _allowed =
        widget.enabled &&
        AmbientMotion.of(context) &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _sync();
    return widget.child;
  }
}

/// Paints the ambient layer over the sky and behind the sun, path and dose
/// marks (see `HorizonLayer`), and under the scene's words: twinkle
/// stars, soft clouds, and the settled glow. Cheap primitives only (ovals,
/// circles, lines, one cached radial gradient); no layers, no blur.
class AmbientSkyPainter extends CustomPainter {
  AmbientSkyPainter({
    required this.model,
    required this.layout,
    required this.drift,
    required this.dark,
    this.collapse,
  }) : super(repaint: Listenable.merge([drift, ?collapse]));

  final HorizonModel model;
  final AmbientLayout layout;
  final AmbientDrift drift;
  final bool dark;
  final ValueListenable<double>? collapse;

  /// Test hook: counts every paint.
  static int debugPaintCount = 0;

  /// Upper bound of cloud opacity at any point: where three puffs overlap
  /// and all their passes stack. Kept low enough that text over the sky
  /// keeps its contrast (see tests).
  static double peakCloudAlpha({required bool dark}) => dark ? .18 : .6;

  /// Light clouds are two-tone: a white body over a lavender underside and a
  /// thin lavender rim, so they read by hue and edge instead of by opacity on
  /// a pale sky. Their stacked peak (1 - (1-.4)(1-.2)(1-.15) = .592) stays
  /// within [peakCloudAlpha].
  static const double lightBodyPeak = .4;
  static const double lightShadePeak = .2;
  static const double lightRimAlpha = .15;
  static const _lightShade = Color(0xFFD0CFEC);

  /// Opacity of one oval pass: the body's peak spread over three overlapping
  /// puffs of [AmbientCloud.passes] each.
  static double cloudPassAlpha({required bool dark}) =>
      (dark ? peakCloudAlpha(dark: true) : lightBodyPeak) /
      (AmbientCloud.passes.length * 3);

  static const _darkCloud = Color(0xFFB4AEF2);
  static const _warm = Color(0xFFFFC9A8);
  static const _golden = Color(0xFFFFC27A);

  final Paint _cloudPaint = Paint();
  final Paint _rimPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  final Paint _starPaint = Paint();
  final Paint _sparklePaint = Paint()
    ..strokeWidth = .8
    ..strokeCap = StrokeCap.round;
  Paint? _glowPaint;
  double _glowKey = -1;

  @override
  void paint(Canvas canvas, Size size) {
    debugPaintCount++;
    if (model.highContrast) return;
    final fade = 1 - (collapse?.value ?? 0).clamp(0.0, 1.0);
    if (fade <= 0) return;
    final t = drift.time;
    _paintStars(canvas, t, fade);
    final mood = AmbientMood.of(
      dayness: model.dayness,
      starAlpha: model.starAlpha,
      share: drift.share ?? AmbientMood.careShare(model.recorded, model.total),
    );
    _paintClouds(canvas, size, t, mood, fade);
    _paintGlow(canvas, size, fade);
  }

  void _paintStars(Canvas canvas, double t, double fade) {
    final alpha = model.starAlpha * fade;
    if (alpha <= .02) return;
    final peak = dark ? .8 : .45;
    final ink = dark ? Colors.white : const Color(0xFF6E66FA);
    for (final star in layout.stars) {
      final a = alpha * peak * (.3 + .7 * star.twinkleAt(t));
      _starPaint.color = ink.withValues(alpha: a);
      canvas.drawCircle(star.position, star.radius, _starPaint);
      if (star.sparkle) {
        final arm = 2.5 + 2 * star.twinkleAt(t);
        final p = star.position;
        _sparklePaint.color = ink.withValues(alpha: a * .6);
        canvas.drawLine(
          p.translate(-arm, 0),
          p.translate(arm, 0),
          _sparklePaint,
        );
        canvas.drawLine(
          p.translate(0, -arm),
          p.translate(0, arm),
          _sparklePaint,
        );
      }
    }
  }

  void _paintClouds(
    Canvas canvas,
    Size size,
    double t,
    AmbientMood mood,
    double fade,
  ) {
    if (mood.cover <= .01) return;
    final twilight = (1 - model.dayness - model.starAlpha).clamp(0.0, 1.0);
    final base = dark
        ? Color.lerp(_darkCloud, _warm, twilight * .3)!
        : Color.lerp(Colors.white, _warm, twilight * .18)!;
    final perPass = cloudPassAlpha(dark: dark);
    // Recording opens a gap around the sun: clouds part sideways.
    final part = (mood.base - mood.cover).clamp(0.0, 1.0) * 26;
    final clouds = layout.clouds;
    for (var i = 0; i < clouds.length; i++) {
      final weight = AmbientLayout.cloudWeight(i, mood.cover);
      if (weight <= 0) continue;
      final cloud = clouds[i];
      final x = cloud.xAt(t, size.width, part: part);
      final scale = math.max(.85, .7 + .3 * weight);
      canvas.save();
      canvas.translate(x, cloud.y);
      canvas.scale(scale);
      if (!dark) {
        // Underside and rim in the lavender of the palette: shape by hue.
        final shadePass =
            lightShadePeak / (AmbientCloud.passes.length * 3) * weight * fade;
        _cloudPaint.color = _lightShade.withValues(alpha: shadePass);
        canvas.save();
        canvas.translate(0, 2.5);
        for (final oval in cloud.ovals) {
          canvas.drawOval(oval, _cloudPaint);
        }
        canvas.restore();
      }
      _cloudPaint.color = base.withValues(alpha: perPass * weight * fade);
      for (final oval in cloud.ovals) {
        canvas.drawOval(oval, _cloudPaint);
      }
      if (!dark) {
        _rimPaint.color = _lightShade.withValues(
          alpha: lightRimAlpha * weight * fade,
        );
        canvas.drawPath(_rimOf(cloud), _rimPaint);
      }
      canvas.restore();
    }
  }

  void _paintGlow(Canvas canvas, Size size, double fade) {
    final g = drift.glow * fade;
    if (g <= .01) return;
    final key = (g * 64).roundToDouble() / 64;
    final cx = model.sun?.dx ?? model.moon?.dx ?? size.width / 2;
    final radius = size.width * .55;
    final center = Offset(cx, model.horizonY);
    if (_glowPaint == null || _glowKey != key) {
      _glowKey = key;
      final color = dark ? _golden : _warm;
      final peak = (dark ? .14 : .28) * key;
      _glowPaint = Paint()
        ..shader = ui.Gradient.radial(
          center,
          radius,
          [
            color.withValues(alpha: peak),
            color.withValues(alpha: peak * .35),
            color.withValues(alpha: 0),
          ],
          const [0, .45, 1],
        );
    }
    // Sky only: the glow sits behind the ridge, never on the page below.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, size.width, model.horizonY - 2));
    canvas.drawCircle(center, radius, _glowPaint!);
    canvas.restore();
  }

  @override
  bool shouldRepaint(AmbientSkyPainter old) =>
      old.model != model ||
      old.layout != layout ||
      old.dark != dark ||
      old.drift != drift;
}

class _Lcg {
  _Lcg(this._s);
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x7fffffff;
  }
}
