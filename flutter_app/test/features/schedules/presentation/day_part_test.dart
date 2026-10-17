import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/schedules/presentation/day_part.dart';
import 'package:simpastil/l10n/app_localizations.dart';

void main() {
  test('times fall into calm day parts', () {
    expect(dayPartOf(const TimeOfDay(hour: 5, minute: 0)), DayPart.morning);
    expect(dayPartOf(const TimeOfDay(hour: 11, minute: 59)), DayPart.morning);
    expect(dayPartOf(const TimeOfDay(hour: 12, minute: 0)), DayPart.afternoon);
    expect(dayPartOf(const TimeOfDay(hour: 17, minute: 0)), DayPart.evening);
    expect(dayPartOf(const TimeOfDay(hour: 21, minute: 0)), DayPart.night);
    expect(dayPartOf(const TimeOfDay(hour: 4, minute: 59)), DayPart.night);
  });

  testWidgets('the spoken label says each time on the phone\'s clock', (
    tester,
  ) async {
    const times = [
      TimeOfDay(hour: 8, minute: 0),
      TimeOfDay(hour: 20, minute: 30),
    ];
    final said = <bool, String>{};
    for (final use24 in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(alwaysUse24HourFormat: use24),
            child: Builder(
              builder: (context) {
                said[use24] = spokenTimesLabel(context, times);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    }
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(said[false], '8:00 AM, ${l.r07_morning}; 8:30 PM, ${l.r07_evening}');
    expect(said[true], '08:00, ${l.r07_morning}; 20:30, ${l.r07_evening}');
  });
}
