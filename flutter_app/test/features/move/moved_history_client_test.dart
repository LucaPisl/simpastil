import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/move/moved_history_client.dart';

Map<String, dynamic> _entry(Object? stateVersion) => {
  'occurrenceId': 'occ-1',
  'occurrenceKey': 'key-1',
  'stateVersion': stateVersion,
  'created': true,
};

void main() {
  group('MovedOccurrence.fromJson', () {
    test('reads the decimal string the server sends', () {
      final entry = MovedOccurrence.fromJson(_entry('0'));
      expect(entry.stateVersion, 0);
      expect(MovedOccurrence.fromJson(_entry('12')).stateVersion, 12);
    });

    test('still accepts a number', () {
      expect(MovedOccurrence.fromJson(_entry(3)).stateVersion, 3);
    });

    test('rejects a missing or non-numeric version', () {
      expect(
        () => MovedOccurrence.fromJson(_entry(null)),
        throwsFormatException,
      );
      expect(
        () => MovedOccurrence.fromJson(_entry('x')),
        throwsFormatException,
      );
    });
  });
}
