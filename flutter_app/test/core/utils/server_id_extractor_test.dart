import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/utils/server_id_extractor.dart';

void main() {
  group('extractServerId', () {
    test('returns direct id string', () {
      expect(extractServerId({'id': 'abc-123'}), equals('abc-123'));
    });

    test('returns nested data.id string', () {
      expect(
        extractServerId({
          'data': {'id': 'nested-456'},
        }),
        equals('nested-456'),
      );
    });

    test('prefers direct id over nested', () {
      expect(
        extractServerId({
          'id': 'direct',
          'data': {'id': 'nested'},
        }),
        equals('direct'),
      );
    });

    test('returns null when map is null', () {
      expect(extractServerId(null), isNull);
    });

    test('returns null when id is missing', () {
      expect(extractServerId({'foo': 'bar'}), isNull);
    });

    test('returns null when id is not a String', () {
      expect(extractServerId({'id': 42}), isNull);
    });

    test('returns null when data exists but has no id', () {
      expect(
        extractServerId({
          'data': {'foo': 'bar'},
        }),
        isNull,
      );
    });
  });
}
