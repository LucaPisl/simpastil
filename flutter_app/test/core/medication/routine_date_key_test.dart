import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/routine_definition.dart';

/// The one date key every feature uses for a routine's local day. Analytics
/// and the low-stock dismissal share it instead of keeping their own copies,
/// so a change here moves them all together.
void main() {
  test('writes a zero padded year, month and day', () {
    expect(routineDateKey(DateTime(2026, 10, 6)), '2026-10-06');
    expect(routineDateKey(DateTime(2026, 1, 31)), '2026-01-31');
    expect(routineDateKey(DateTime(987, 3, 9)), '0987-03-09');
  });

  test('ignores the time of day and does not shift across midnight', () {
    expect(routineDateKey(DateTime(2026, 12, 31, 23, 59, 59)), '2026-12-31');
    expect(routineDateKey(DateTime(2027, 1, 1, 0, 0, 1)), '2027-01-01');
  });

  test('keys sort in calendar order across month and year ends', () {
    final days = [
      for (var i = 0; i < 70; i++) DateTime(2026, 11, 20 + i),
    ].map(routineDateKey).toList();
    expect([...days]..sort(), days);
  });
}
