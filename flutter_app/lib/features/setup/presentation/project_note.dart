import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../updates/presentation/update_available_card.dart';
import '../project_links.dart';

typedef DonationLink = ({String label, String url, String keyName});

/// The short, honest note before the summary of first-run setup: Simpastil is
/// a small independent project, and where to say so when something breaks.
/// The links open outside the app, through the same launcher as the release
/// page (overridden in tests).
///
/// It plays a short entrance once: a heart that beats, the three ways to take
/// part spreading out around it, then one card for each sliding in. With
/// reduced motion everything is simply there.
class SetupProjectNote extends ConsumerStatefulWidget {
  const SetupProjectNote({super.key, this.header, this.donationLinks});

  /// The page title and body, shown under the heart and over the cards.
  final Widget? header;

  /// The donation pages to offer. Defaults to the ones in
  /// `project_links.dart` that are filled in.
  final List<DonationLink>? donationLinks;

  @override
  ConsumerState<SetupProjectNote> createState() => _SetupProjectNoteState();
}

class _SetupProjectNoteState extends ConsumerState<SetupProjectNote>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _entrance.value = 1;
    } else {
      _entrance.forward();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  void _open(Uri uri) {
    // Opening is a courtesy: with no browser to hand there is nothing to say.
    Future<void>.sync(() => ref.read(updateLauncherProvider)(uri)).ignore();
  }

  /// Fades and lifts [child] into place over its slice of the entrance.
  Widget _rise(double start, Widget child) {
    final curve = CurvedAnimation(
      parent: _entrance,
      curve: Interval(
        start,
        math.min(start + .45, 1),
        curve: Curves.easeOutCubic,
      ),
    );
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, .12),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final donations =
        widget.donationLinks ??
        [
          if (githubSponsorsUrl != null)
            (
              label: l.onb_projectSponsors,
              url: githubSponsorsUrl!,
              keyName: 'project-sponsors',
            ),
          (label: l.onb_projectKofi, url: kofiUrl, keyName: 'project-kofi'),
        ];
    final tones = <_Tone>[
      _Tone(
        Icons.bug_report_rounded,
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      _Tone(
        Icons.code_rounded,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      if (donations.isNotEmpty)
        _Tone(
          Icons.local_cafe_rounded,
          colors.primaryContainer,
          colors.onPrimaryContainer,
        ),
    ];
    final cards = <Widget>[
      _NoteCard(
        tone: tones[0],
        title: l.onb_projectProblemTitle,
        body: l.onb_projectProblemBody,
        actions: [
          FilledButton.tonalIcon(
            key: const ValueKey('project-report'),
            onPressed: () => _open(issuesUrl),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(l.onb_projectReport),
          ),
        ],
      ),
      _NoteCard(
        tone: tones[1],
        title: l.onb_projectHelpTitle,
        body: l.onb_projectHelpBody,
        actions: [
          FilledButton.tonalIcon(
            key: const ValueKey('project-code'),
            onPressed: () => _open(repositoryUrl),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(l.onb_projectCode),
          ),
        ],
      ),
      if (donations.isNotEmpty)
        _NoteCard(
          key: const ValueKey('project-support'),
          tone: tones[2],
          title: l.onb_projectSupportTitle,
          body: l.onb_projectSupportBody,
          actions: [
            for (final link in donations)
              FilledButton.tonalIcon(
                key: ValueKey(link.keyName),
                onPressed: () => _open(Uri.parse(link.url)),
                icon: Icon(
                  link.keyName == 'project-kofi'
                      ? Icons.local_cafe_rounded
                      : Icons.favorite_rounded,
                ),
                label: Text(link.label),
              ),
          ],
        ),
    ];
    return Column(
      key: const ValueKey('project-note'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: _ProjectHero(animation: _entrance, satellites: tones),
        ),
        const SizedBox(height: 12),
        if (widget.header != null) _rise(.15, widget.header!),
        for (final (i, card) in cards.indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          _rise(.3 + i * .12, card),
        ],
        const SizedBox(height: 28),
      ],
    );
  }
}

class _Tone {
  const _Tone(this.icon, this.fill, this.ink);
  final IconData icon;
  final Color fill, ink;
}

/// One way to take part: an icon in its colour, a title, a line and buttons.
class _NoteCard extends StatelessWidget {
  const _NoteCard({
    super.key,
    required this.tone,
    required this.title,
    required this.body,
    required this.actions,
  });
  final _Tone tone;
  final String title, body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), text = theme.textTheme;
    final colors = theme.colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: tone.fill,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(tone.icon, color: tone.ink, size: 24),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: text.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (final (i, action) in actions.indexed) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: action),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A heart in a soft circle with the ways to take part around it on a thin
/// orbit. On entrance the circle grows, the heart beats twice, the orbit draws
/// itself and each icon travels out from the heart to its place.
class _ProjectHero extends StatelessWidget {
  const _ProjectHero({required this.animation, required this.satellites});
  final Animation<double> animation;
  final List<_Tone> satellites;

  static const _height = 156.0, _badge = 84.0, _bubble = 40.0, _orbit = 80.0;
  static const _center = Offset(_badge / 2, _height / 2);
  static const _angles = [-40.0, 0.0, 40.0];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final grow = CurvedAnimation(
      parent: animation,
      curve: const Interval(0, .35, curve: Curves.easeOutBack),
    );
    final beat =
        TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 1, end: 1.18), weight: 25),
          TweenSequenceItem(tween: Tween(begin: 1.18, end: .94), weight: 20),
          TweenSequenceItem(tween: Tween(begin: .94, end: 1.1), weight: 25),
          TweenSequenceItem(tween: Tween(begin: 1.1, end: 1), weight: 30),
        ]).animate(
          CurvedAnimation(parent: animation, curve: const Interval(.3, .75)),
        );
    final orbit = CurvedAnimation(
      parent: animation,
      curve: const Interval(.1, .6, curve: Curves.easeInOut),
    );
    return SizedBox(
      height: _height,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) => Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _OrbitPainter(
                  center: _center,
                  radius: _orbit,
                  progress: orbit.value,
                  color: colors.outlineVariant,
                ),
              ),
            ),
            Positioned(
              left: _center.dx - _badge / 2,
              top: _center.dy - _badge / 2,
              child: Transform.scale(
                scale: .4 + .6 * grow.value,
                child: Container(
                  width: _badge,
                  height: _badge,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: colors.primary.withValues(alpha: .1),
                        blurRadius: 24,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Transform.scale(
                    scale: beat.value,
                    child: Icon(
                      Icons.favorite_rounded,
                      size: 40,
                      color: colors.primary,
                    ),
                  ),
                ),
              ),
            ),
            for (final (i, tone) in satellites.indexed) _satellite(i, tone),
          ],
        ),
      ),
    );
  }

  Widget _satellite(int i, _Tone tone) {
    final start = .2 + i * .1;
    final travel = CurvedAnimation(
      parent: animation,
      curve: Interval(start, start + .4, curve: Curves.easeOutBack),
    );
    final appear = CurvedAnimation(
      parent: animation,
      curve: Interval(start, start + .15),
    );
    final angle = _angles[i] * math.pi / 180;
    final target = _center + Offset(math.cos(angle), math.sin(angle)) * _orbit;
    final at = Offset.lerp(_center, target, travel.value)!;
    return Positioned(
      left: at.dx - _bubble / 2,
      top: at.dy - _bubble / 2,
      child: Opacity(
        opacity: appear.value,
        child: Transform.scale(
          scale: .3 + .7 * travel.value.clamp(0, 1.2),
          child: Container(
            width: _bubble,
            height: _bubble,
            decoration: BoxDecoration(
              color: tone.fill,
              shape: BoxShape.circle,
              border: Border.all(color: tone.ink.withValues(alpha: .12)),
            ),
            child: Icon(tone.icon, size: 20, color: tone.ink),
          ),
        ),
      ),
    );
  }
}

/// A thin arc right of the heart, on which the icons sit, drawn from the top
/// as [progress] grows.
class _OrbitPainter extends CustomPainter {
  const _OrbitPainter({
    required this.center,
    required this.radius,
    required this.progress,
    required this.color,
  });
  final Offset center;
  final double radius, progress;
  final Color color;

  static const _arc = 140 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -_arc / 2,
      _arc * progress,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.progress != progress || old.color != color;
}
