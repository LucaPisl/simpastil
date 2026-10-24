import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/sync/schedule_repair_intent.dart';

Map<String, dynamic> _doc([Map<String, dynamic> extra = const {}]) => {
  'hour': 8,
  'minute': 0,
  'frequency': 'daily',
  'frequencyDays': null,
  'isActive': true,
  'timeZone': 'Europe/Bucharest',
  ...extra,
};

void main() {
  test('a plain document is valid exactly as before', () {
    expect(ScheduleRepairIntent.validDocument(_doc()), isTrue);
  });

  test('an interval document needs its interval, anchor and no days', () {
    final interval = _doc({
      'frequency': 'interval',
      'everyDays': 3,
      'anchorDate': '2026-10-01',
    });
    expect(ScheduleRepairIntent.validDocument(interval), isTrue);
    expect(
      ScheduleRepairIntent.validDocument({
        ...interval,
        'frequencyDays': [1],
      }),
      isFalse,
    );
    expect(
      ScheduleRepairIntent.validDocument({...interval, 'everyDays': null}),
      isFalse,
    );
    expect(
      ScheduleRepairIntent.validDocument({...interval, 'everyDays': 0}),
      isFalse,
    );
    expect(
      ScheduleRepairIntent.validDocument({...interval, 'anchorDate': null}),
      isFalse,
    );
  });

  test('dates are validated for every non-as-needed frequency', () {
    expect(
      ScheduleRepairIntent.validDocument(
        _doc({'startDate': '2026-06-01', 'endDate': '2026-06-30'}),
      ),
      isTrue,
    );
    expect(
      ScheduleRepairIntent.validDocument(
        _doc({'startDate': '2026-06-30', 'endDate': '2026-06-01'}),
      ),
      isFalse,
    );
    expect(
      ScheduleRepairIntent.validDocument(_doc({'startDate': '2026-02-30'})),
      isFalse,
    );
    expect(ScheduleRepairIntent.validDocument(_doc({'everyDays': 2})), isFalse);
    expect(ScheduleRepairIntent.validDocument(_doc({'startDate': 5})), isFalse);
    expect(
      ScheduleRepairIntent.validDocument(
        _doc({'frequency': 'prn', 'startDate': '2026-06-01'}),
      ),
      isFalse,
    );
  });
}
