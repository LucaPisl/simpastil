import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/notification_action_handler.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';

const _userId = '00000000-0000-4000-8000-000000000001';
const _occurrenceId = '00000000-0000-4000-8000-000000000002';

String _payload({
  int generation = 3,
  String? projectionId,
  Map<String, Object?> extra = const {},
}) => jsonEncode({
  'occurrenceId': _occurrenceId,
  'projectionId':
      projectionId ??
      reminderProjectionId(
        userId: _userId,
        sessionGeneration: generation,
        occurrenceId: _occurrenceId,
        kind: 'reminder',
      ),
  'userId': _userId,
  'sessionGeneration': generation,
  ...extra,
});

void main() {
  group('occurrence reminder payload', () {
    test('contains only the four approved identity fields', () {
      final raw = _payload();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(decoded.keys.toSet(), {
        'occurrenceId',
        'projectionId',
        'userId',
        'sessionGeneration',
      });
      expect(parseReminderActionPayload(raw)?.occurrenceId, _occurrenceId);
      expect(
        extractRouteFromPayload(raw),
        '/home?dose=${Uri.encodeQueryComponent(_occurrenceId)}',
      );
    });

    test('rejects legacy schedule/name data and malformed payloads', () {
      expect(
        parseReminderActionPayload(
          _payload(extra: const {'pillName': 'Private name'}),
        ),
        isNull,
      );
      expect(parseReminderActionPayload('not-json'), isNull);
      expect(parseReminderActionPayload('{"scheduleId":"old"}'), isNull);
    });

    test(
      'accepts actions only for the same generation and exact projection',
      () {
        final payload = parseReminderActionPayload(_payload())!;
        expect(reminderActionIsCurrent(payload, (_userId, 3)), isTrue);
        expect(reminderActionIsCurrent(payload, (_userId, 4)), isFalse);
        expect(reminderActionIsCurrent(payload, ('another-user', 3)), isFalse);

        const spoofed = ReminderActionPayload(
          occurrenceId: _occurrenceId,
          projectionId: 'not-the-reminder-projection',
          userId: _userId,
          sessionGeneration: 3,
        );
        expect(reminderActionIsCurrent(spoofed, (_userId, 3)), isFalse);
      },
    );

    test('notification action command ID is stable for platform replay', () {
      final projectionId = reminderProjectionId(
        userId: _userId,
        sessionGeneration: 3,
        occurrenceId: _occurrenceId,
        kind: 'reminder',
      );
      final first = notificationActionCommandId(
        projectionId: projectionId,
        occurrenceId: _occurrenceId,
        action: 'take',
        stateVersion: 0,
      );
      final replay = notificationActionCommandId(
        projectionId: projectionId,
        occurrenceId: _occurrenceId,
        action: 'take',
        stateVersion: 0,
      );
      final nextState = notificationActionCommandId(
        projectionId: projectionId,
        occurrenceId: _occurrenceId,
        action: 'take',
        stateVersion: 2,
      );

      expect(first, replay);
      expect(first, isNot(nextState));
    });
  });
}
