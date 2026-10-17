import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/format/clock.dart';

typedef _Said = ({
  String time,
  String at,
  String hour,
  String stamp,
  bool twelve,
});

Future<_Said> _say(
  WidgetTester tester, {
  required String locale,
  required bool use24,
}) async {
  late _Said said;
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(alwaysUse24HourFormat: use24),
        child: Builder(
          builder: (context) {
            said = (
              time: clockTime(context, const TimeOfDay(hour: 20, minute: 5)),
              at: clockAt(context, DateTime(2026, 3, 1, 7, 45)),
              hour: clockHour(context, 8),
              stamp: clockDateTime(context, DateTime(2026, 10, 13, 13, 13)),
              twelve: usesTwelveHourClock(context),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return said;
}

void main() {
  testWidgets('English on a 12-hour phone reads AM and PM', (tester) async {
    final said = await _say(tester, locale: 'en', use24: false);
    expect(said.twelve, isTrue);
    expect(said.time, '8:05 PM');
    expect(said.at, '7:45 AM');
    expect(said.hour, '8 AM');
    expect(said.stamp, 'Oct 13, 2026 1:13 PM');
  });

  testWidgets('a 24-hour phone reads 24-hour times in any language', (
    tester,
  ) async {
    for (final locale in ['en', 'ro']) {
      final said = await _say(tester, locale: locale, use24: true);
      expect(said.twelve, isFalse, reason: locale);
      expect(said.time, '20:05', reason: locale);
      expect(said.at, '07:45', reason: locale);
      expect(said.hour, '08:00', reason: locale);
      expect(said.stamp, endsWith(' 13:13'), reason: locale);
    }
  });

  testWidgets('Romanian keeps its own 24-hour clock', (tester) async {
    final said = await _say(tester, locale: 'ro', use24: false);
    expect(said.twelve, isFalse);
    expect(said.time, '20:05');
    expect(said.hour, '08:00');
  });
}
