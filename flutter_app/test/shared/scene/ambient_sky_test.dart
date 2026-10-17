import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/motion/ambient_motion.dart';
import 'package:simpastil/shared/motion/overlay_presence.dart';
import 'package:simpastil/shared/scene/ambient_sky.dart';
import 'package:simpastil/shared/scene/horizon_painter.dart';
import 'package:simpastil/shared/scene/horizon_scene.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

import 'scene_test_support.dart';

Color _over(Color top, double alpha, Color bottom) => Color.from(
  alpha: 1,
  red: top.r * alpha + bottom.r * (1 - alpha),
  green: top.g * alpha + bottom.g * (1 - alpha),
  blue: top.b * alpha + bottom.b * (1 - alpha),
);

void main() {
  group('mood', () {
    test('clouds only ever thin as doses are recorded', () {
      for (final (dayness, stars) in [(1.0, 0.0), (0.0, 1.0), (0.0, 0.0)]) {
        var last = double.infinity;
        for (var r = 0; r <= 6; r++) {
          final mood = AmbientMood.of(
            dayness: dayness,
            starAlpha: stars,
            share: AmbientMood.careShare(r, 6),
          );
          expect(mood.cover, lessThan(last));
          expect(mood.cover, lessThanOrEqualTo(mood.base));
          last = mood.cover;
        }
        expect(last, 0, reason: 'all recorded clears the sky');
      }
    });

    test('nothing recorded is never heavier than the time of day', () {
      final none = AmbientMood.of(dayness: 1, starAlpha: 0, share: 0);
      expect(none.cover, none.base);
      final nothingPlanned = AmbientMood.of(
        dayness: 1,
        starAlpha: 0,
        share: AmbientMood.careShare(0, 0),
      );
      expect(nothingPlanned.cover, lessThan(none.cover));
      expect(nothingPlanned.cover, greaterThan(0));
    });

    test('time of day sets the base: day fullest, night thin', () {
      final day = AmbientMood.baseFor(dayness: 1, starAlpha: 0);
      final twilight = AmbientMood.baseFor(dayness: 0, starAlpha: 0);
      final night = AmbientMood.baseFor(dayness: 0, starAlpha: 1);
      expect(day, greaterThan(twilight));
      expect(twilight, greaterThan(night));
      expect(night, greaterThan(0));
    });

    test('clouds thin out one at a time', () {
      expect(AmbientLayout.cloudWeight(0, 1), 1);
      expect(AmbientLayout.cloudWeight(AmbientLayout.cloudCount - 1, 1), 1);
      expect(AmbientLayout.cloudWeight(AmbientLayout.cloudCount - 1, .5), 0);
      expect(AmbientLayout.cloudWeight(0, .5), 1);
      expect(AmbientLayout.cloudWeight(0, 0), 0);
    });
  });

  group('layout', () {
    test('deterministic for a size and seed, different for another seed', () {
      final a = AmbientLayout.compute(size: sceneSize, horizonY: 136);
      final b = AmbientLayout.compute(size: sceneSize, horizonY: 136);
      final c = AmbientLayout.compute(size: sceneSize, horizonY: 136, seed: 5);
      for (var i = 0; i < a.clouds.length; i++) {
        expect(a.clouds[i].x0, b.clouds[i].x0);
        expect(a.clouds[i].ovals, b.clouds[i].ovals);
        expect(a.clouds[i].xAt(40, 390), b.clouds[i].xAt(40, 390));
      }
      expect(a.clouds.first.x0, isNot(c.clouds.first.x0));
    });

    test('clouds and stars stay in the upper sky, clear of the marks', () {
      final model = modelFor(at(12, 0), Brightness.light);
      final layout = AmbientLayout.compute(
        size: model.size,
        horizonY: model.horizonY,
      );
      final highestMark = model.marks
          .map((m) => m.rect.top)
          .reduce((a, b) => a < b ? a : b);
      for (final cloud in layout.clouds) {
        for (final oval in cloud.ovals) {
          expect(cloud.y + oval.bottom, lessThan(highestMark - 8));
        }
      }
      for (final star in layout.stars) {
        expect(star.position.dy, lessThan(highestMark - 8));
      }
    });

    test('drift wraps around and keeps moving rightward', () {
      final cloud = AmbientLayout.compute(
        size: sceneSize,
        horizonY: 136,
      ).clouds.first;
      expect(cloud.xAt(1, 390), greaterThan(cloud.xAt(0, 390)));
      for (var t = 0.0; t < 2000; t += 37) {
        final x = cloud.xAt(t, 390);
        expect(x, greaterThanOrEqualTo(-cloud.width * .6 - 1e-6));
        expect(x, lessThanOrEqualTo(390 + cloud.width * .6 + 1e-6));
      }
    });
  });

  group('text contrast over clouds', () {
    for (final b in Brightness.values) {
      test('${b.name}: title 7:1 and secondary 4.5:1 at peak cloud', () {
        final scheme = themeFor(b).colorScheme;
        final dark = b == Brightness.dark;
        final cloud = dark ? const Color(0xFFFFC9A8) : Colors.white;
        final alpha = AmbientSkyPainter.peakCloudAlpha(dark: dark);
        // Light clouds are two-tone: stack the body, underside and rim at
        // their peaks, the worst case anywhere in a cloud.
        Color behindText(Color sky) {
          if (dark) return _over(cloud, alpha, sky);
          var c = _over(
            const Color(0xFFD0CFEC),
            AmbientSkyPainter.lightShadePeak,
            sky,
          );
          c = _over(cloud, AmbientSkyPainter.lightBodyPeak, c);
          return _over(
            const Color(0xFFD0CFEC),
            AmbientSkyPainter.lightRimAlpha,
            c,
          );
        }

        for (var minute = 0; minute < 1440; minute += 13) {
          final model = modelFor(at(minute ~/ 60, minute % 60), b);
          for (var y = 0.0; y <= model.horizonY; y += 20) {
            final bg = behindText(model.skyColorAt(y));
            expect(
              AppTheme.contrast(scheme.onSurface, bg),
              greaterThanOrEqualTo(7),
            );
            expect(
              AppTheme.contrast(scheme.onSurfaceVariant, bg),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
      });
    }
  });

  test('two-tone light clouds stay within the peak opacity', () {
    const stacked =
        1 -
        (1 - AmbientSkyPainter.lightBodyPeak) *
            (1 - AmbientSkyPainter.lightShadePeak) *
            (1 - AmbientSkyPainter.lightRimAlpha);
    expect(
      stacked,
      lessThanOrEqualTo(AmbientSkyPainter.peakCloudAlpha(dark: false)),
    );
  });

  group('drift controller', () {
    test('inactive: no timers, care applied at once', () {
      fakeAsync((async) {
        final drift = AmbientDrift();
        drift.setCare(recorded: 0, total: 4);
        drift.setCare(recorded: 2, total: 4);
        expect(drift.share, .5);
        async.elapse(const Duration(minutes: 2));
        expect(drift.debugTicks, 0);
        expect(async.pendingTimers, isEmpty);
        drift.dispose();
      });
    });

    test('drifts at about 15 fps, rests, then stops after the idle limit', () {
      fakeAsync((async) {
        final drift = AmbientDrift()..setCare(recorded: 0, total: 2);
        drift.active = true;
        async.elapse(const Duration(seconds: 1));
        expect(drift.debugTicks, inInclusiveRange(14, 16));
        async.elapse(AmbientDrift.windowLength);
        expect(drift.isDrifting, isFalse);
        expect(drift.isResting, isTrue);
        final atRest = drift.debugTicks;
        final time = drift.time;
        async.elapse(AmbientDrift.restLength - const Duration(seconds: 1));
        expect(drift.debugTicks, atRest, reason: 'no frames while resting');
        expect(drift.time, time);
        async.elapse(const Duration(seconds: 2));
        expect(drift.isDrifting, isTrue);
        // Long after the last touch everything stops for good.
        async.elapse(AmbientDrift.idleLimit + const Duration(minutes: 1));
        expect(drift.isDrifting, isFalse);
        expect(drift.isResting, isFalse);
        final stopped = drift.debugTicks;
        async.elapse(const Duration(minutes: 5));
        expect(drift.debugTicks, stopped);
        drift.wake();
        expect(drift.isDrifting, isTrue);
        drift.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('drift is deterministic for the same sequence of ticks', () {
      double run() {
        late double t;
        fakeAsync((async) {
          final drift = AmbientDrift()..active = true;
          async.elapse(const Duration(seconds: 7));
          t = drift.time;
          drift.dispose();
        });
        return t;
      }

      expect(run(), run());
      expect(run(), greaterThan(0));
    });

    test('a recording eases the mood and wakes a resting sky', () {
      fakeAsync((async) {
        final drift = AmbientDrift()..setCare(recorded: 0, total: 2);
        drift.active = true;
        async.elapse(AmbientDrift.windowLength + const Duration(seconds: 1));
        expect(drift.isResting, isTrue);
        drift.setCare(recorded: 2, total: 2);
        expect(drift.isDrifting, isTrue);
        async.elapse(const Duration(milliseconds: 400));
        expect(drift.share, inExclusiveRange(0, 1));
        expect(drift.glow, inExclusiveRange(0, 1));
        async.elapse(const Duration(seconds: 25));
        expect(drift.share, 1);
        expect(drift.glow, 1);
        drift.dispose();
      });
    });

    test('glow only when everything planned is recorded', () {
      final drift = AmbientDrift()..setCare(recorded: 3, total: 4);
      expect(drift.glow, 0);
      drift.setCare(recorded: 4, total: 4);
      expect(drift.glow, 1);
      drift.setCare(recorded: 0, total: 0);
      expect(drift.glow, 0);
      expect(drift.share, isNull);
      drift.dispose();
    });

    test('turning off stops at once and snaps to the still mood', () {
      fakeAsync((async) {
        final drift = AmbientDrift()..setCare(recorded: 0, total: 2);
        drift.active = true;
        async.elapse(const Duration(seconds: 2));
        drift.setCare(recorded: 1, total: 2);
        drift.active = false;
        expect(drift.share, .5);
        expect(async.pendingTimers, isEmpty);
        drift.dispose();
      });
    });
  });

  group('driver', () {
    Widget host(
      AmbientDrift drift, {
      bool ambient = true,
      bool ticker = true,
      bool disableAnimations = false,
      bool enabled = true,
      ValueNotifier<double>? collapse,
    }) {
      final model = modelFor(at(12, 0), Brightness.light);
      Widget child = MaterialApp(
        theme: themeFor(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: TickerMode(
            enabled: ticker,
            child: Scaffold(
              body: AmbientSkyDriver(
                drift: drift,
                enabled: enabled,
                collapse: collapse,
                child: SizedBox.fromSize(
                  size: model.size,
                  child: HorizonScene(
                    model: model,
                    semanticsLabel: 'sky',
                    ambient: drift,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (ambient) child = AmbientMotion(enabled: true, child: child);
      return child;
    }

    Future<int> paintsOver(WidgetTester tester, Duration d) async {
      final before = AmbientSkyPainter.debugPaintCount;
      // Pump like a 60 Hz display, so the count shows the drift's own rate.
      final steps = d.inMilliseconds ~/ 16;
      for (var i = 0; i < steps; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      return AmbientSkyPainter.debugPaintCount - before;
    }

    testWidgets('drifts while visible, at a reduced frame rate', (
      tester,
    ) async {
      final drift = AmbientDrift();
      await tester.pumpWidget(host(drift));
      await tester.pump(const Duration(seconds: 1));
      expect(drift.isDrifting, isTrue);
      final paints = await paintsOver(tester, const Duration(seconds: 2));
      expect(paints, inInclusiveRange(26, 32), reason: '~15 fps for 2 s');
      final sky = HorizonPainter.debugPaintCount;
      await paintsOver(tester, const Duration(seconds: 1));
      expect(
        HorizonPainter.debugPaintCount,
        sky,
        reason: 'drift frames do not re-record the sky itself',
      );
      await tester.pumpWidget(const SizedBox());
      drift.dispose();
    });

    testWidgets('never runs without the app opting in', (tester) async {
      final drift = AmbientDrift();
      await tester.pumpWidget(host(drift, ambient: false));
      await tester.pump(const Duration(seconds: 1));
      expect(drift.isDrifting, isFalse);
      expect(await paintsOver(tester, const Duration(seconds: 2)), 0);
      await tester.pumpWidget(const SizedBox());
      drift.dispose();
    });

    for (final (name, build) in <(String, Widget Function(AmbientDrift))>[
      ('reduced motion', (d) => host(d, disableAnimations: true)),
      ('a hidden tab (TickerMode off)', (d) => host(d, ticker: false)),
      ('high contrast (disabled by owner)', (d) => host(d, enabled: false)),
    ]) {
      testWidgets('still composition under $name', (tester) async {
        final drift = AmbientDrift();
        await tester.pumpWidget(build(drift));
        await tester.pump(const Duration(seconds: 1));
        expect(drift.isDrifting, isFalse);
        expect(drift.isResting, isFalse);
        expect(await paintsOver(tester, const Duration(seconds: 2)), 0);
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpWidget(const SizedBox());
        drift.dispose();
      });
    }

    testWidgets('stops when backgrounded and resumes on return', (
      tester,
    ) async {
      final drift = AmbientDrift();
      await tester.pumpWidget(host(drift));
      await tester.pump(const Duration(seconds: 1));
      expect(drift.isDrifting, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(drift.isDrifting, isFalse);
      expect(await paintsOver(tester, const Duration(seconds: 3)), 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(drift.isDrifting, isTrue);
      await tester.pumpWidget(const SizedBox());
      drift.dispose();
    });

    testWidgets('stops under a sheet and when the header scrolls away', (
      tester,
    ) async {
      final drift = AmbientDrift();
      final collapse = ValueNotifier<double>(0);
      await tester.pumpWidget(host(drift, collapse: collapse));
      await tester.pump(const Duration(seconds: 1));
      expect(drift.isDrifting, isTrue);

      final context = tester.element(find.byType(AmbientSkyDriver));
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 80),
      );
      await tester.pump();
      expect(drift.isDrifting, isFalse);
      Navigator.of(context).pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(drift.isDrifting, isTrue);

      collapse.value = 1;
      expect(drift.isDrifting, isFalse);
      expect(await paintsOver(tester, const Duration(seconds: 2)), 0);
      collapse.value = .5;
      expect(drift.isDrifting, isTrue);

      await tester.pumpWidget(const SizedBox());
      drift.dispose();
      collapse.dispose();
    });

    testWidgets('clouds are painted between the sky and the bodies', (
      tester,
    ) async {
      final drift = AmbientDrift();
      await tester.pumpWidget(host(drift));
      final scene = tester.widget<CustomPaint>(
        find
            .descendant(
              of: find.byType(HorizonScene),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      expect((scene.painter! as HorizonPainter).layer, HorizonLayer.backdrop);
      expect(scene.child, isNotNull, reason: 'clouds sit between the layers');
      expect(
        (scene.foregroundPainter! as HorizonPainter).layer,
        HorizonLayer.bodies,
      );
      await tester.pumpWidget(const SizedBox());
      drift.dispose();
    });

    testWidgets(
      'a root dialog over a nested Today rests the drift and wakes it after',
      (tester) async {
        final drift = AmbientDrift();
        final overlays = OverlayPresenceObserver();
        addTearDown(overlays.dispose);
        final model = modelFor(at(12, 0), Brightness.light);
        await tester.pumpWidget(
          AmbientMotion(
            enabled: true,
            overlayOpen: overlays.open,
            child: MaterialApp(
              theme: themeFor(Brightness.light),
              navigatorObservers: [overlays],
              home: Scaffold(
                // Today lives in its own navigator, like the app's shell.
                body: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => AmbientSkyDriver(
                      drift: drift,
                      child: SizedBox.fromSize(
                        size: model.size,
                        child: HorizonScene(
                          model: model,
                          semanticsLabel: 'sky',
                          ambient: drift,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(drift.isDrifting, isTrue);

        final context = tester.element(find.byType(AmbientSkyDriver));
        showDialog<void>(
          context: context,
          useRootNavigator: true,
          builder: (_) => const AlertDialog(title: Text('Fictional dialog')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(overlays.open.value, isTrue);
        expect(drift.isDrifting, isFalse);
        expect(await paintsOver(tester, const Duration(seconds: 2)), 0);

        Navigator.of(context, rootNavigator: true).pop();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(overlays.open.value, isFalse);
        expect(drift.isDrifting, isTrue);

        await tester.pumpWidget(const SizedBox());
        drift.dispose();
      },
    );
  });
}
