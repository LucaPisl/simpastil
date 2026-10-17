import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/scene/horizon_model.dart';
import 'package:simpastil/shared/scene/scene_clock.dart';
import 'package:simpastil/shared/scene/sun_table.dart';

import 'scene_test_support.dart';

void main() {
  HorizonModel at4(DateTime now, {DateTime? date}) => modelFor(
    now,
    Brightness.light,
    date: date ?? DateTime(now.year, now.month, now.day),
    doses: const [],
  );

  group('phase', () {
    final apr = DateTime(2026, 4, 15);
    HorizonPhase phase(int h, [DateTime? d]) {
      final day = d ?? apr;
      return at4(DateTime(day.year, day.month, day.day, h), date: day).phase;
    }

    test('06 dawn, 12 day, 19 dusk, 23 night in April', () {
      expect(phase(6), HorizonPhase.dawn);
      expect(phase(12), HorizonPhase.day);
      expect(phase(19), HorizonPhase.dusk);
      expect(phase(23), HorizonPhase.night);
      expect(phase(2), HorizonPhase.night);
    });

    test('winter sunsets are earlier than summer sunsets', () {
      final jan = SunTable.forDate(DateTime(2026, 1, 20));
      final jun = SunTable.forDate(DateTime(2026, 6, 20));
      expect(jan.sunset, lessThan(jun.sunset));
      expect(jan.sunrise, greaterThan(jun.sunrise));
      expect(phase(18, DateTime(2026, 12, 15)), HorizonPhase.night);
    });

    test('sun table is continuous across month boundaries', () {
      for (final d in [
        DateTime(2026, 1, 1),
        DateTime(2026, 12, 31),
        DateTime(2026, 3, 31),
        DateTime(2026, 4, 1),
      ]) {
        final a = SunTable.forDate(d);
        final b = SunTable.forDate(d.add(const Duration(days: 1)));
        expect((a.sunrise - b.sunrise).abs(), lessThan(40));
        expect((a.sunset - b.sunset).abs(), lessThan(40));
      }
    });

    test('a past day shows its evening, a future day shows dawn', () {
      final now = DateTime(2026, 4, 15, 12);
      final past = at4(now, date: DateTime(2026, 4, 10));
      final future = at4(now, date: DateTime(2026, 4, 20));
      expect(past.phase, HorizonPhase.dusk);
      expect(future.phase, HorizonPhase.dawn);
      expect(at4(now, date: DateTime(2026, 4, 15)).phase, HorizonPhase.day);
    });
  });

  group('celestial bodies', () {
    test('sun is up by day and never with the moon', () {
      final day = at4(DateTime(2026, 4, 15, 12));
      expect(day.sun, isNotNull);
      expect(day.moon, isNull);
      expect(day.sun!.dy, lessThan(day.horizonY - 40));
      final night = at4(DateTime(2026, 4, 15, 23));
      expect(night.sun, isNull);
      expect(night.moon, isNotNull);
    });

    test('sun moves left to right through the day', () {
      final a = at4(DateTime(2026, 4, 15, 8)).sun!;
      final b = at4(DateTime(2026, 4, 15, 14)).sun!;
      final c = at4(DateTime(2026, 4, 15, 19)).sun!;
      expect(a.dx, lessThan(b.dx));
      expect(b.dx, lessThan(c.dx));
    });

    test('moon phase follows the synodic cycle', () {
      final newMoon = HorizonModel.moonPhaseOf(DateTime(2026, 4, 17));
      final fullMoon = HorizonModel.moonPhaseOf(DateTime(2026, 5, 1));
      expect(newMoon < .08 || newMoon > .92, isTrue);
      expect((fullMoon - .5).abs(), lessThan(.08));
    });
  });

  group('marks', () {
    test('doses without a planned time (PRN) get no mark', () {
      final m = modelFor(at(12, 0), Brightness.light);
      expect(m.marks.any((x) => x.id == 'p'), isFalse);
      expect(m.total, 8);
    });

    test('marks follow the 24 hour axis left to right', () {
      final m = modelFor(at(12, 0), Brightness.light);
      final xs = m.marks.map((x) => x.rect.center.dx).toList();
      expect(xs, [...xs]..sort());
      expect(m.marks.first.rect.center.dx, greaterThan(HorizonModel.sideInset));
      expect(m.marks.last.rect.center.dx, lessThan(sceneSize.width));
    });

    test('same-minute doses fan out along the day path', () {
      final m = modelFor(
        at(12, 0),
        Brightness.light,
        doses: const [
          HorizonDose(
            id: '1',
            plannedLocalTime: '08:00:00',
            state: 'taken',
            person: 'a',
          ),
          HorizonDose(
            id: '2',
            plannedLocalTime: '08:00:00',
            state: 'pending',
            person: 'b',
          ),
          HorizonDose(
            id: '3',
            plannedLocalTime: '08:00:00',
            state: 'pending',
            person: 'c',
          ),
        ],
      );
      expect(m.marks, hasLength(3));
      final xs = m.marks.map((x) => x.rect.center.dx).toList();
      expect(xs[1] - xs[0], HorizonModel.stackStep);
      expect(xs[2] - xs[1], HorizonModel.stackStep);
      // The group is centred on its minute.
      final minuteX =
          HorizonModel.sideInset +
          480 / 1440 * (sceneSize.width - 2 * HorizonModel.sideInset);
      expect(xs[1], closeTo(minuteX, .001));
      for (final mark in m.marks) {
        expect(
          mark.rect.center.dy,
          closeTo(
            HorizonModel.pathY(
              mark.rect.center.dx,
              sceneSize.width,
              m.pathBaseY,
              m.pathLift,
            ),
            .001,
          ),
        );
      }
      expect(m.marks.any((x) => x.hidden), isFalse);
    });

    test('more than three collapse onto the third disc and keep ids', () {
      final doses = [
        for (var i = 0; i < 5; i++)
          HorizonDose(
            id: 'd$i',
            plannedLocalTime: '08:00',
            state: 'pending',
            person: 'a',
          ),
      ];
      final m = modelFor(at(12, 0), Brightness.light, doses: doses);
      expect(m.marks, hasLength(5));
      expect(m.marks.where((x) => x.hidden), hasLength(2));
      expect(m.marks[3].rect, m.marks[2].rect);
      expect(m.nearestMark(m.marks[2].rect.center)!.id, 'd2');
    });

    test('different minutes do not stack', () {
      final m = modelFor(
        at(12, 0),
        Brightness.light,
        doses: const [
          HorizonDose(
            id: '1',
            plannedLocalTime: '08:00',
            state: 'taken',
            person: 'a',
          ),
          HorizonDose(
            id: '2',
            plannedLocalTime: '08:01',
            state: 'taken',
            person: 'a',
          ),
        ],
      );
      expect(m.marks[0].rect.center.dx, lessThan(m.marks[1].rect.center.dx));
      expect(m.marks[0].rect.center.dy, closeTo(m.marks[1].rect.center.dy, .2));
    });

    test('marks sit on a gentle arc that peaks at midday', () {
      HorizonDose dose(String id, String time) => HorizonDose(
        id: id,
        plannedLocalTime: time,
        state: 'pending',
        person: 'a',
      );
      final m = modelFor(
        at(12, 0),
        Brightness.light,
        doses: [dose('a', '01:00'), dose('b', '12:00'), dose('c', '23:00')],
      );
      final ys = m.marks.map((x) => x.rect.center.dy).toList();
      expect(ys[1], lessThan(ys[0] - 8));
      expect(ys[1], lessThan(ys[2] - 8));
      expect(m.pathLift, lessThanOrEqualTo(14));
      // Capsules stay above the horizon.
      for (final mark in m.marks) {
        expect(mark.rect.bottom, lessThan(m.horizonY));
      }
    });

    test('capsules are big enough to notice', () {
      expect(HorizonModel.markBounds.width, greaterThanOrEqualTo(14));
      expect(HorizonModel.markBounds.height, greaterThanOrEqualTo(18));
    });

    test(
      'next mark is the first pending dose, day progress follows the clock',
      () {
        final m = modelFor(at(12, 0), Brightness.light);
        expect(m.nextMark?.id, 'c');
        expect(m.dayProgress, closeTo(.5, .001));
        expect(
          modelFor(
            at(12, 0),
            Brightness.light,
            date: DateTime(2026, 4, 20),
          ).dayProgress,
          1,
        );
      },
    );

    test('settled only when everything is taken or skipped', () {
      const taken = HorizonDose(
        id: '1',
        plannedLocalTime: '08:00',
        state: 'taken',
        person: 'a',
      );
      const skipped = HorizonDose(
        id: '2',
        plannedLocalTime: '09:00',
        state: 'skipped',
        person: 'a',
      );
      const open = HorizonDose(
        id: '3',
        plannedLocalTime: '10:00',
        state: 'pending',
        person: 'a',
      );
      expect(
        modelFor(
          at(12, 0),
          Brightness.light,
          doses: const [taken, skipped],
        ).settled,
        isTrue,
      );
      expect(
        modelFor(
          at(12, 0),
          Brightness.light,
          doses: const [taken, open],
        ).settled,
        isFalse,
      );
      expect(
        modelFor(at(12, 0), Brightness.light, doses: const []).settled,
        isFalse,
      );
    });

    test('hit test shares the drawn rects and honours the 24 dp reach', () {
      final m = modelFor(at(12, 0), Brightness.light);
      final first = m.marks.first;
      expect(
        m.nearestMark(first.rect.center + const Offset(-3, 8))?.id,
        first.id,
      );
      expect(m.nearestMark(first.rect.center + const Offset(0, -60)), isNull);
      expect(m.nearestMarkByX(first.rect.center.dx + 2)?.id, isNotNull);
    });
  });

  group('scene clock', () {
    test('parses HH:MM and rejects junk', () {
      final base = DateTime(2026, 4, 15, 3);
      expect(parseSceneTime('19:45', base), DateTime(2026, 4, 15, 19, 45));
      expect(parseSceneTime('25:00', base), isNull);
      expect(parseSceneTime('noon', base), isNull);
    });
  });

  test('the moon never sits on a dose mark', () {
    final doses = [
      for (var h = 0; h < 24; h++)
        HorizonDose(
          id: 'h$h',
          plannedLocalTime: '${h.toString().padLeft(2, '0')}:00:00',
          state: 'pending',
          person: 'Ana',
        ),
    ];
    var moons = 0;
    for (final size in const [Size(411, 190), Size(360, 150), Size(640, 240)]) {
      for (var minute = 0; minute < 1440; minute += 10) {
        final now = DateTime(2026, 10, 12, minute ~/ 60, minute % 60);
        final model = HorizonModel.compute(
          date: DateTime(2026, 10, 12),
          now: now,
          b: Brightness.light,
          highContrast: false,
          doses: doses,
          size: size,
        );
        final moon = model.moon;
        if (moon == null) continue;
        moons++;
        for (final mark in model.marks) {
          final zone = mark.rect.inflate(HorizonModel.moonRadius);
          expect(zone.contains(moon), isFalse, reason: '$now $size ${mark.id}');
        }
      }
    }
    expect(moons, greaterThan(50));
  });

  group('header text zones', () {
    const zone = Rect.fromLTWH(20, 100, 150, 90);

    test('a body behind the words drops below them when there is room', () {
      final c = HorizonModel.clearOfText(const Offset(60, 130), 11, [
        zone,
      ], lowest: 300)!;
      expect(c.dy, greaterThanOrEqualTo(zone.bottom + 11));
      expect(c.dx, 60);
    });

    test('with no room below it rises above, then gives way', () {
      final up = HorizonModel.clearOfText(const Offset(60, 130), 11, [
        zone,
      ], lowest: 150)!;
      expect(up.dy, lessThanOrEqualTo(zone.top - 11));
      expect(
        HorizonModel.clearOfText(const Offset(60, 20), 11, [
          const Rect.fromLTWH(20, 0, 150, 200),
        ], lowest: 100),
        isNull,
      );
    });

    test('a clear body and an empty zone list are left alone', () {
      const c = Offset(300, 130);
      expect(HorizonModel.clearOfText(c, 11, [zone], lowest: 300), c);
      expect(HorizonModel.clearOfText(c, 11, const [], lowest: 300), c);
    });

    group('parallax shift', () {
      test('a body resting below the words never drifts up into them', () {
        const rest = Offset(60, 210);
        for (var shift = -120.0; shift <= 20; shift += 4) {
          final c = HorizonModel.keepClearOfText(
            rest,
            rest.translate(0, shift),
            11,
            [zone],
          );
          expect(
            zone.inflate(11).contains(c),
            isFalse,
            reason: 'shift $shift lands at $c',
          );
          expect(c.dy, greaterThanOrEqualTo(zone.bottom + 11));
        }
      });

      test('a body resting above the words never sinks into them', () {
        const rest = Offset(60, 60);
        for (var shift = -20.0; shift <= 120; shift += 4) {
          final c = HorizonModel.keepClearOfText(
            rest,
            rest.translate(0, shift),
            11,
            [zone],
          );
          expect(zone.inflate(11).contains(c), isFalse);
          expect(c.dy, lessThanOrEqualTo(zone.top - 11));
        }
      });

      test('a body beside the words and a still body are left alone', () {
        const side = Offset(300, 130);
        expect(
          HorizonModel.keepClearOfText(side, side.translate(0, -30), 11, [
            zone,
          ]),
          side.translate(0, -30),
        );
        const rest = Offset(60, 210);
        expect(HorizonModel.keepClearOfText(rest, rest, 11, [zone]), rest);
      });

      test('compute keeps the zones so the painter can apply the shift', () {
        final m = HorizonModel.compute(
          date: DateTime(2026, 4, 15),
          now: DateTime(2026, 4, 15, 22),
          b: Brightness.dark,
          highContrast: false,
          doses: const [],
          size: const Size(412, 300),
          textZones: const [Rect.fromLTWH(20, 90, 360, 90)],
        );
        expect(m.textZones, const [Rect.fromLTWH(20, 90, 360, 90)]);
      });
    });

    test('compute never leaves the sun or moon inside a zone', () {
      for (var h = 0; h < 24; h++) {
        final now = DateTime(2026, 4, 15, h, 30);
        final m = HorizonModel.compute(
          date: DateTime(2026, 4, 15),
          now: now,
          b: Brightness.dark,
          highContrast: false,
          doses: const [],
          size: const Size(412, 300),
          textZones: const [
            Rect.fromLTWH(20, 90, 360, 90),
            Rect.fromLTWH(20, 180, 300, 30),
          ],
        );
        for (final body in [m.sun, m.moon]) {
          if (body == null) continue;
          for (final z in const [
            Rect.fromLTWH(20, 90, 360, 90),
            Rect.fromLTWH(20, 180, 300, 30),
          ]) {
            expect(z.inflate(11).contains(body), isFalse, reason: 'hour $h');
          }
        }
      }
    });
  });

  group('constellation', () {
    final night = DateTime(2026, 10, 13, 23);

    test('only taken doses become stars, each above its own mark', () {
      final m = modelFor(night, Brightness.dark);
      final taken = {
        for (final mark in m.marks)
          if (mark.state == HorizonMarkState.taken) mark.id: mark,
      };
      expect(m.constellation, isNotEmpty);
      for (final star in m.constellation) {
        final mark = taken[star.id];
        expect(mark, isNotNull, reason: '${star.id} is not a taken dose');
        expect(star.origin, mark!.rect.center);
        expect(star.home.dy, lessThan(mark.rect.top - 20));
        expect(star.home.dx, inInclusiveRange(10, m.size.width - 10));
      }
      for (final a in m.constellation) {
        for (final b in m.constellation) {
          if (identical(a, b)) continue;
          expect((a.home - b.home).distance, greaterThanOrEqualTo(18));
        }
      }
    });

    test('a star keeps its place through the day', () {
      final day = modelFor(DateTime(2026, 10, 13, 12, 30), Brightness.light);
      final late = modelFor(night, Brightness.dark);
      expect(
        [for (final s in day.constellation) (s.id, s.home)],
        [for (final s in late.constellation) (s.id, s.home)],
      );
    });

    test('stars stay out of the header words and the moon', () {
      const words = Rect.fromLTWH(0, 0, 412, 120);
      final m = HorizonModel.compute(
        date: DateTime(2026, 10, 13),
        now: night,
        b: Brightness.dark,
        highContrast: false,
        doses: sampleDoses,
        size: const Size(412, 300),
        textZones: const [words],
      );
      for (final star in m.constellation) {
        expect(
          words.inflate(HorizonModel.starRadius - .5).contains(star.home),
          isFalse,
        );
        final moon = m.moon;
        if (moon != null) {
          expect(
            (star.home - moon).distance,
            greaterThan(HorizonModel.moonRadius + 8),
          );
        }
      }
    });

    test('no taken doses, no constellation', () {
      final m = modelFor(
        night,
        Brightness.dark,
        doses: [
          for (final d in sampleDoses)
            if (d.state != 'taken') d,
        ],
      );
      expect(m.constellation, isEmpty);
    });
  });
}
