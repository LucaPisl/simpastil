import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/history_quiet_day.dart';
import 'package:simpastil/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

QuietPathPainter _path(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byKey(const ValueKey('history-quiet-path')),
            )
            .painter!
        as QuietPathPainter;

void main() {
  final day = DateTime(2026, 10, 7);

  testWidgets('a day before the phone knew the person says so', (tester) async {
    await tester.pumpWidget(
      _host(
        HistoryQuietDay(
          day: day,
          earlier: DateTime(2026, 10, 2),
          later: DateTime(2026, 10, 12),
          seenFrom: DateTime(2026, 10, 10, 18),
          person: 'Mira',
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Wednesday, October 7'), findsOneWidget);
    expect(find.text('Before Mira was on this device'), findsOneWidget);
    expect(
      find.text(
        'Mira has been on this device since Saturday, October 10. '
        'Days before that have no records here.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Nothing recorded'), findsNothing);
    // Nothing earlier is on this device: the thread is tied off here.
    expect(find.textContaining('Earlier:'), findsNothing);
    expect(find.text('Later: Mon, Oct 12'), findsOneWidget);
    expect(_path(tester).knot, isTrue);
  });

  testWidgets('for everyone it speaks of the phone, not a person', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        HistoryQuietDay(
          day: day,
          seenFrom: DateTime(2026, 10, 10),
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Before care began on this device'), findsOneWidget);
    expect(
      find.text(
        'Care on this device began on Saturday, October 10. '
        'Days before that have no records here.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a quiet day the phone did see reads as before', (tester) async {
    await tester.pumpWidget(
      _host(
        HistoryQuietDay(
          day: DateTime(2026, 10, 11),
          earlier: DateTime(2026, 10, 2),
          seenFrom: DateTime(2026, 10, 10),
          person: 'Mira',
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing recorded on Sunday, October 11'), findsOneWidget);
    expect(find.textContaining('this device since'), findsNothing);
    expect(find.text('Earlier: Fri, Oct 2'), findsOneWidget);
    expect(_path(tester).knot, isFalse);
  });
}
