import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/features/dashboard/today_side/coming_up.dart';

ComingUpDose _dose(String pill, String name, int day, String time) {
  final hour = int.parse(time.substring(0, 2));
  final minute = int.parse(time.substring(3, 5));
  return ComingUpDose(
    pillId: pill,
    medication: name,
    personName: 'Me',
    localDate: '2026-10-${day.toString().padLeft(2, '0')}',
    localTime: time,
    plannedAt: DateTime.utc(2026, 10, day, hour, minute),
    amount: const MedicationAmount.unknown(),
  );
}

void main() {
  test('one dose per medication, soonest first', () {
    final doses = soonestDoses([
      _dose('a', 'Alpha', 18, '08:00'),
      _dose('a', 'Alpha', 17, '08:00'),
      _dose('b', 'Beta', 17, '07:00'),
      _dose('c', 'Gamma', 17, '21:00'),
    ]);
    expect(doses.map((d) => d.medication), ['Beta', 'Alpha', 'Gamma']);
    expect(doses[1].localDate, '2026-10-17');
  });

  test('keeps only the limit', () {
    final doses = soonestDoses([
      for (var i = 0; i < 6; i++) _dose('p$i', 'Med $i', 17, '0${i + 1}:00'),
    ]);
    expect(doses, hasLength(comingUpLimit));
    expect(doses.map((d) => d.pillId), ['p0', 'p1', 'p2']);
    expect(soonestDoses(const []), isEmpty);
    expect(
      soonestDoses([
        for (var i = 0; i < 6; i++) _dose('p$i', 'Med $i', 17, '0${i + 1}:00'),
      ], limit: 5),
      hasLength(5),
    );
  });

  test('equal times fall back to the medication name', () {
    final doses = soonestDoses([
      _dose('b', 'Beta', 17, '08:00'),
      _dose('a', 'Alpha', 17, '08:00'),
    ]);
    expect(doses.map((d) => d.medication), ['Alpha', 'Beta']);
  });
}
