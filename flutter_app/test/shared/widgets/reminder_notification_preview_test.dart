import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/reminder_copy.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/reminder_notification_preview.dart';

final _light = AppTheme.light();

Widget _host(bool fullDetails, {bool quiet = false}) => MaterialApp(
  theme: _light,
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: quiet),
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: ReminderNotificationPreview.sample(
            AppLocalizations.of(context),
            fullDetails: fullDetails,
          ),
        ),
      ),
    ),
  ),
);

List<InkBarPainter> _ink(WidgetTester tester) => [
  for (final paint in tester.widgetList<CustomPaint>(
    find.descendant(
      of: find.byType(ReminderNotificationPreview),
      matching: find.byType(CustomPaint),
    ),
  ))
    if (paint.foregroundPainter is InkBarPainter)
      paint.foregroundPainter! as InkBarPainter,
];

void main() {
  late AppLocalizations l;
  setUpAll(() async {
    l = await AppLocalizations.delegate.load(const Locale('en'));
  });

  String named() => l.core_notifTitle(l.r6_sampleMedicine);

  test('the ink covers block after block, then leaves the same way', () {
    for (var i = 0; i < 3; i++) {
      expect(InkBarPainter.coverAt(0, i), 0);
      expect(InkBarPainter.coverAt(InkBarPainter.swap, i), 1);
      expect(InkBarPainter.leaveAt(InkBarPainter.swap, i), 0);
      expect(InkBarPainter.leaveAt(1, i), 1);
    }
    expect(
      InkBarPainter.coverAt(.1, 0),
      greaterThan(InkBarPainter.coverAt(.1, 1)),
    );
  });

  test('the ink eases onto shorter words and never bares longer ones', () {
    const short = Size(100, 20), long = Size(160, 20);
    expect(InkBarPainter.boxAt(.2, long, short), short);
    expect(InkBarPainter.boxAt(InkBarPainter.swap, long, short), long);
    expect(InkBarPainter.boxAt(1, long, short), short);
    for (final t in [InkBarPainter.swap, .5, 1.0]) {
      expect(InkBarPainter.boxAt(t, short, long), long);
    }
    expect(InkBarPainter.boxAt(.5, null, short), short);
  });

  testWidgets('slides in once when it first appears', (tester) async {
    await tester.pumpWidget(_host(true));
    await tester.pump();
    await tester.pump(ReminderNotificationPreview.entry ~/ 2);
    final opacity = tester.widget<Opacity>(
      find
          .descendant(
            of: find.byType(ReminderNotificationPreview),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('going private inks the name over, then shows the private '
      'wording', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(true));
    await tester.pumpAndSettle();
    expect(find.text(named()), findsOneWidget);
    expect(_ink(tester), isEmpty);

    await tester.pumpWidget(_host(false));
    expect(
      find.bySemanticsLabel(RegExp(l.core_notifPrivateTitle)),
      findsOneWidget,
      reason: 'a screen reader hears the new choice at once',
    );
    await tester.pump();
    await tester.pump(ReminderNotificationPreview.inking * .2);
    expect(find.text(named()), findsOneWidget, reason: 'still under the ink');
    expect(_ink(tester), hasLength(3));
    expect(_ink(tester).every((p) => p.redact), isTrue);

    await tester.pump(ReminderNotificationPreview.inking * .4);
    expect(find.text(named()), findsNothing);
    expect(find.text(l.core_notifPrivateTitle), findsOneWidget);
    expect(find.text(l.core_notifActionOpen), findsOneWidget);
    expect(find.text(l.core_notifActionSnooze), findsNothing);

    await tester.pumpAndSettle();
    expect(_ink(tester), isEmpty);
    expect(tester.binding.hasScheduledFrame, isFalse);
    handle.dispose();
  });

  testWidgets('coming back wipes the ink off the names', (tester) async {
    await tester.pumpWidget(_host(false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(true));
    await tester.pump();
    await tester.pump(ReminderNotificationPreview.inking * .2);
    expect(find.text(l.core_notifPrivateTitle), findsOneWidget);
    expect(_ink(tester).every((p) => !p.redact), isTrue);
    await tester.pumpAndSettle();
    expect(find.text(named()), findsOneWidget);
    expect(_ink(tester), isEmpty);
  });

  testWidgets('quiet motion shows the new wording at once', (tester) async {
    await tester.pumpWidget(_host(true, quiet: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(_host(false, quiet: true));
    await tester.pump();
    expect(find.text(l.core_notifPrivateTitle), findsOneWidget);
    expect(_ink(tester), isEmpty);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a narrow card keeps the time together on one line', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _light,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 210,
                child: ReminderNotificationPreview.planned(
                  AppLocalizations.of(context),
                  copy: doseReminderCopy(
                    AppLocalizations.of(context),
                    fullDetails: true,
                    pillName: l.r6_sampleMedicine,
                    dosage: l.r6_sampleDose,
                  ),
                  when: '8:00 PM',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final meta = find.textContaining('Simpastil');
    expect(meta, findsOneWidget);
    expect(tester.widget<Text>(meta).data, endsWith('8:00\u00A0PM'));
    // Even in a card too narrow for the whole line, the time stays on one
    // line: every glyph box of "8:00 PM" shares the same top edge.
    final data = tester.widget<Text>(meta).data!;
    final paragraph = tester.renderObject<RenderParagraph>(meta);
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: data.length - 7, extentOffset: data.length),
    );
    expect(boxes, isNotEmpty);
    expect(boxes.map((b) => b.top).toSet(), hasLength(1));
    expect(
      paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: data.length),
          )
          .map((b) => b.top)
          .toSet()
          .length,
      greaterThan(1),
      reason: 'the card is narrow enough that the line does wrap',
    );
  });
}
