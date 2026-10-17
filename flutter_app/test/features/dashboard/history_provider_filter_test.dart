import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/history_provider.dart';
import 'package:simpastil/features/dashboard/models/history_entry.dart';

HistoryEntry _entry({
  required String source,
  required String occurrenceState,
  required String status,
}) => HistoryEntry(
  doseLogId: 'o1',
  pillName: 'Ibuprofen',
  scheduledAt: null,
  status: status,
  profileName: 'Alex',
  scheduleId: 's1',
  source: source,
  occurrenceState: occurrenceState,
);

void main() {
  test('an undone as-needed dose is not listed in History', () {
    expect(
      shouldListInHistory(
        _entry(source: 'prn', occurrenceState: 'pending', status: 'pending'),
      ),
      isFalse,
    );
  });

  test('a taken as-needed dose is listed', () {
    expect(
      shouldListInHistory(
        _entry(source: 'prn', occurrenceState: 'taken', status: 'taken'),
      ),
      isTrue,
    );
  });

  test('a scheduled pending occurrence with no events stays unlisted', () {
    expect(
      shouldListInHistory(
        _entry(
          source: 'scheduled',
          occurrenceState: 'pending',
          status: 'pending',
        ),
      ),
      isFalse,
    );
  });
}
