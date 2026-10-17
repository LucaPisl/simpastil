import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/features/dashboard/dose_detail_screen.dart';
import 'package:simpastil/features/dashboard/dose_story.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

const _stations = [
  DoseStation(title: 'Planned for 09:00', kind: DoseStationKind.done),
  DoseStation(
    title: 'Taken at 09:15',
    aside: '15 min after the plan',
    kind: DoseStationKind.done,
  ),
  DoseStation(
    title: 'Saved here · waiting to share',
    kind: DoseStationKind.waiting,
  ),
];

Widget _host(
  List<DoseStation> stations, {
  bool quiet = false,
  double scale = 1,
}) => MaterialApp(
  theme: AppTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(412, 914),
      disableAnimations: quiet,
      textScaler: TextScaler.linear(scale),
    ),
    child: Scaffold(
      body: SingleChildScrollView(child: DoseStory(stations: stations)),
    ),
  ),
);

double _landed(WidgetTester tester, int i) => tester
    .widget<CustomPaint>(find.byKey(ValueKey('dose-story-rail-$i')))
    .painter!
    .let((p) => (p as DoseRailPainter).landed);

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('offset words', () {
    final l = lookupAppLocalizations(const Locale('en'));
    final ro = lookupAppLocalizations(const Locale('ro'));

    test('within five minutes is the planned time', () {
      expect(
        doseStoryOffset(l, const Duration(minutes: 4)),
        'At the planned time',
      );
      expect(
        doseStoryOffset(l, const Duration(minutes: -4)),
        'At the planned time',
      );
    });

    test('later and earlier say how far, in hours past an hour', () {
      expect(
        doseStoryOffset(l, const Duration(minutes: 15)),
        '15 min after the plan',
      );
      expect(
        doseStoryOffset(l, const Duration(minutes: -95)),
        '1 h 35 min before the plan',
      );
      expect(
        doseStoryOffset(ro, const Duration(minutes: 20)),
        '20 min după plan',
      );
    });
  });

  testWidgets('stations land one after another, then the rail rests', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_stations));
    expect(_landed(tester, 0), 0);
    await tester.pump(DoseStory.duration * .3);
    expect(_landed(tester, 0), greaterThan(0));
    expect(_landed(tester, 2), 0);
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      expect(_landed(tester, i), moreOrLessEquals(1));
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('quiet motion shows the whole story at once', (tester) async {
    await tester.pumpWidget(_host(_stations, quiet: true));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      expect(_landed(tester, i), 1);
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a story that moves on replays only from what changed', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_stations));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host([
        ..._stations.take(2),
        const DoseStation(
          title: 'Accepted by shared care',
          kind: DoseStationKind.done,
        ),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(_landed(tester, 0), 1);
    expect(_landed(tester, 1), 1);
    expect(_landed(tester, 2), lessThan(1));
    await tester.pumpAndSettle();
    expect(find.text('Accepted by shared care'), findsOneWidget);
  });

  testWidgets('each station reads as one sentence; the rail is silent', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(_stations));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel('Taken at 09:15\n15 min after the plan'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('large text wraps without clipping', (tester) async {
    await tester.pumpWidget(_host(_stations, scale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('15 min after the plan'), findsOneWidget);
  });

  testWidgets('Dose details tell the recorded dose as a story, sharing once', (
    tester,
  ) async {
    final f = await CareRecordingFixture.create();
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => DateTime.utc(2026, 9, 30, 9, 15),
    );
    await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
        amount: const MedicationAmount.unknown(),
      ),
    );
    final container = await f.workspace.createContainer();
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DoseDetailScreen(occurrenceId: f.occurrence.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final story = find.byType(DoseStory);
    expect(story, findsOneWidget);
    String inStory(String text) => tester
        .widget<Text>(find.descendant(of: story, matching: find.text(text)))
        .data!;
    expect(inStory('Planned for 9:00 AM'), isNotEmpty);
    expect(
      find.descendant(of: story, matching: find.textContaining('Taken at ')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: story, matching: find.textContaining('the plan')),
      findsOneWidget,
    );
    expect(find.text('Saved on this device'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
