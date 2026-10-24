import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/features/profiles/presentation/person_day_line.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/scene/dose_bead.dart';
import 'package:simpastil/shared/scene/scene_clock.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

final _at = DateTime(2026, 10, 13, 12);

Profile _person(String id) => Profile(
  id: id,
  userId: 'u',
  name: 'Mira $id',
  avatarEmoji: '',
  isActive: true,
  createdAt: _at,
  updatedAt: _at,
  revision: 1,
  syncStatus: 'synced',
  isDeleted: false,
);

/// A fictional day: each dose is (id, "HH:MM", state, as needed).
CareDay _day(
  List<(String, String, String, bool)> doses, {
  String person = 'a',
}) {
  final who = _person(person);
  final pill = Pill(
    id: 'pill',
    stockNeedsRecount: false,
    profileId: who.id,
    name: 'Vitamin D',
    isPrn: false,
    createdAt: _at,
    updatedAt: _at,
    revision: 1,
    syncStatus: 'synced',
    isDeleted: false,
  );
  final snapshot = ScheduleSnapshotV1(
    pillName: 'Vitamin D',
    dosage: null,
    frequency: 'daily',
    frequencyDays: null,
    hour: 8,
    minute: 0,
    timeZone: 'UTC',
    profileId: who.id,
    profileName: who.name,
  );
  return CareDay(
    localDate: '2026-10-13',
    state: CareDayState.pending,
    people: [who],
    prn: const [],
    entries: [
      for (final (id, time, state, prn) in doses)
        CareDayEntry(
          occurrence: MedicationOccurrence(
            id: id,
            userId: 'u',
            occurrenceKey: id,
            source: prn ? 'prn' : 'scheduled',
            plannedLocalDate: '2026-10-13',
            plannedLocalTime: '$time:00',
            timeZone: 'UTC',
            expected: !prn,
            snapshotVersion: 1,
            scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
            provenance: 'exact',
            state: state,
            stateVersion: 1,
            createdAt: _at,
            updatedAt: _at,
          ),
          person: who,
          pill: pill,
          snapshot: snapshot,
          plannedAmount: const MedicationAmount.unknown(),
          sharing: CareSharingOutcome.localOnly,
        ),
    ],
  );
}

class _Selected extends SelectedProfileNotifier {
  @override
  Future<String?> build() async => 'a';
  void pick(String id) => state = AsyncData(id);
}

void main() {
  Widget app(
    Widget child, {
    bool quiet = false,
    List<Override> extra = const [],
  }) => ProviderScope(
    overrides: [sceneClockProvider.overrideWithValue(() => _at), ...extra],
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, page) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: quiet),
        child: page!,
      ),
      home: Scaffold(body: Center(child: child)),
    ),
  );

  Widget line(CareDay care, {PersonDayLocator? locator}) => SizedBox(
    width: 220,
    child: PersonDayLine(personId: 'a', care: care, locator: locator),
  );

  PersonLinePainter painter(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.byKey(const ValueKey('person-day-line')),
              )
              .painter!
          as PersonLinePainter;

  final morningEvening = _day([
    ('m', '08:00', 'taken', false),
    ('e', '20:00', 'pending', false),
    ('p', '15:00', 'taken', true),
  ]);

  testWidgets('draws itself in once, then rests with nothing scheduled', (
    tester,
  ) async {
    await tester.pumpWidget(app(line(morningEvening)));
    expect(painter(tester).draw.value, 0);
    await tester.pump();
    await tester.pump(PersonDayLine.draw ~/ 2);
    expect(painter(tester).draw.value, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    final rested = painter(tester);
    expect(rested.draw.value, 1);
    expect(rested.frame.clusters, hasLength(3));
    expect(rested.complete, isFalse);
    expect(rested.now, 12 * 60);
    expect(tester.binding.hasScheduledFrame, isFalse);
    // The as-needed dose is drawn but never counted as owed.
    expect(find.bySemanticsLabel('1 of 2 taken today'), findsOneWidget);
  });

  testWidgets('quiet motion lands the finished line at once', (tester) async {
    await tester.pumpWidget(app(line(morningEvening), quiet: true));
    await tester.pump();
    expect(painter(tester).draw.value, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the line turns the taken colour once the day is done', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        line(
          _day([
            ('m', '08:00', 'taken', false),
            ('n', '11:00', 'taken', false),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final theme = AppTheme.light();
    expect(painter(tester).complete, isTrue);
    expect(
      painter(tester).line,
      theme.extension<AppSemanticColors>()!.statusTaken,
    );
  });

  testWidgets('doses close together share one dot with a count', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        line(
          _day([
            ('a1', '08:00', 'taken', false),
            ('a2', '08:10', 'pending', false),
            ('b', '19:00', 'pending', false),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final clusters = painter(tester).frame.clusters;
    expect(clusters, hasLength(2));
    expect(clusters.first.doses, hasLength(2));
    // What still needs a look shows first.
    expect(clusters.first.bead, DoseBead.unrecorded);
  });

  testWidgets('a tapped dot shows its words until tapped again or away', (
    tester,
  ) async {
    await tester.pumpWidget(app(line(morningEvening)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('person-line-dot-m')));
    await tester.pumpAndSettle();
    expect(find.text('8:00 AM · Vitamin D · Taken'), findsOneWidget);
    expect(painter(tester).selected, 'm');
    // It may hang left of the line but never past its right end, where the
    // next card starts.
    final lineBox = tester.getRect(find.byType(PersonDayLine));
    final label = tester.getRect(
      find.byKey(const ValueKey('person-line-label-m')),
    );
    expect(label.right, lessThanOrEqualTo(lineBox.right + .01));
    expect(label.left, greaterThanOrEqualTo(20 - .01));
    await tester.tap(find.byKey(const ValueKey('person-line-dot-m')));
    await tester.pumpAndSettle();
    expect(find.text('8:00 AM · Vitamin D · Taken'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('person-line-dot-e')));
    await tester.pumpAndSettle();
    expect(find.text('8:00 PM · Vitamin D · Planned'), findsOneWidget);
    // It never leaves on its own.
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('8:00 PM · Vitamin D · Planned'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('8:00 PM · Vitamin D · Planned'), findsNothing);
    expect(painter(tester).selected, isNull);
  });

  testWidgets('a dose recorded anywhere pops its dot once', (tester) async {
    await tester.pumpWidget(app(line(morningEvening)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      app(
        line(
          _day([
            ('m', '08:00', 'taken', false),
            ('e', '20:00', 'taken', false),
            ('p', '15:00', 'taken', true),
          ]),
        ),
      ),
    );
    expect(painter(tester).popped, {'e'});
    await tester.pump();
    await tester.pump(PersonDayLine.pop ~/ 2);
    expect(
      PersonLinePainter.popScale(painter(tester).pop.value),
      greaterThan(1),
    );
    await tester.pumpAndSettle();
    expect(painter(tester).pop.value, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('press and hold plucks the line; it rings out and settles', (
    tester,
  ) async {
    await tester.pumpWidget(app(line(morningEvening)));
    await tester.pumpAndSettle();
    final box = tester.getRect(find.byKey(const ValueKey('person-day-line')));
    final gesture = await tester.startGesture(
      box.topLeft + Offset(box.width * .3, PersonDayLine.lineY + 6),
    );
    // Not armed by a short press.
    await tester.pump(const Duration(milliseconds: 200));
    expect(painter(tester).bend.value.depth, 0);
    await tester.pump(const Duration(milliseconds: 150));
    final held = painter(tester).bend.value;
    expect(held.depth, StringBend.deflect);
    expect(held.ring, isNull);
    expect(held.at, closeTo(.3, .02));
    // It follows the finger only so far.
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(painter(tester).bend.value.depth, StringBend.reach);
    await gesture.up();
    await tester.pump();
    await tester.pump(StringBend.ringOut ~/ 3);
    expect(painter(tester).bend.value.ring, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(painter(tester).bend.value, StringBend.flat);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  test('a held string is a triangle; let go, it dies away flat', () {
    const held = StringBend(at: .25, depth: 8);
    expect(held.offset(.25), 8);
    expect(held.offset(0), 0);
    expect(held.offset(1), 0);
    expect(held.offset(.625), closeTo(4, 1e-9));
    const late = StringBend(at: .25, depth: 8, ring: .5);
    expect(late.offset(.5).abs(), lessThan(8 * .5));
    const done = StringBend(at: .25, depth: 8, ring: 1);
    expect(done.offset(.5), 0);
  });

  testWidgets('the ring is one summary and opens at the top', (tester) async {
    await tester.pumpWidget(
      app(
        PersonDayRing(
          personId: 'a',
          care: morningEvening,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('1 of 2 taken today'), findsOneWidget);
    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('person-day-ring-a')),
    );
    final ring = paint.foregroundPainter! as RingDayPainter;
    expect(ring.frame.clusters, hasLength(3));
    // The day runs clockwise from one side of the opening to the other.
    double angle(int minute) =>
        RingDayPainter.angleOf(ring.frame, minute.toDouble(), ring.radius);
    const top = -math.pi / 2;
    expect(
      angle(ring.frame.start),
      closeTo(top + PersonDayRing.opening / 2, 1e-9),
    );
    expect(
      angle(ring.frame.end),
      closeTo(top + math.pi * 2 - PersonDayRing.opening / 2, 1e-9),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'a person rising from the rows unrolls their ring into the line',
    (tester) async {
      final selected = _Selected();
      late PersonDayLocator locator;
      await tester.pumpWidget(
        app(
          Consumer(
            builder: (context, ref, _) {
              locator = ref.read(personDayLocatorProvider);
              final focus = ref.watch(selectedProfileIdProvider).asData?.value;
              return PersonUnrollHost(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (focus == 'b')
                      SizedBox(
                        width: 220,
                        child: PersonDayLine(
                          personId: 'b',
                          care: _day([
                            ('m', '08:00', 'taken', false),
                          ], person: 'b'),
                          locator: locator,
                        ),
                      ),
                    const SizedBox(height: 120),
                    if (focus != 'b')
                      PersonDayRing(
                        personId: 'b',
                        care: _day([
                          ('m', '08:00', 'taken', false),
                        ], person: 'b'),
                        locator: locator,
                        child: const SizedBox(),
                      ),
                  ],
                ),
              );
            },
          ),
          extra: [selectedProfileIdProvider.overrideWith(() => selected)],
        ),
      );
      await tester.pumpAndSettle();
      expect(locator.ring('b'), isNotNull);

      selected.pick('b');
      var landed = false;
      locator.landed.then((_) => landed = true);
      expect(locator.veil('b').value, 1);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('person-unroll')), findsOneWidget);
      // The line arriving under the flight is already drawn.
      expect(painter(tester).draw.value, 1);
      await tester.pump(PersonUnrollHost.flight ~/ 2);
      expect(locator.veil('b').value, 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('person-unroll')), findsNothing);
      expect(locator.veil('b').value, 0);
      expect(landed, isTrue);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );
}
