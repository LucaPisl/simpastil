import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/format/clock.dart';

void main() {
  test('a time and its day period never wrap apart', () {
    expect(
      keepTimesWhole('Every day · 9:00 AM · 8:00 pm'),
      'Every day · 9:00 AM · 8:00 pm',
    );
  });

  test('24-hour times and other words are left alone', () {
    expect(keepTimesWhole('Zilnic · 21:00'), 'Zilnic · 21:00');
    expect(keepTimesWhole('2 Amlodipine'), '2 Amlodipine');
  });
}
