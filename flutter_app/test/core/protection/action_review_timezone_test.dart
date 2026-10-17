import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/notifications/notification_action_handler.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/widget/widget_action_handler.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../helpers/care_recording_fixture.dart';

Future<CareRecordingFixture> _fictionalFixture() async {
  tzdata.initializeTimeZones();
  final fixture = await CareRecordingFixture.create(
    routineTimeZone: 'Europe/Bucharest',
    routineHour: 12,
  );
  await fixture.db
      .into(fixture.db.devicePersonReminders)
      .insertOnConflictUpdate(
        DevicePersonRemindersCompanion.insert(
          profileId: fixture.person.id,
          enabled: const Value(true),
        ),
      );
  return fixture;
}

Map<String, Object> _protectedPayload(
  CareRecordingFixture fixture, {
  required String kind,
}) {
  final context = fixture.workspace.context;
  final occurrence = fixture.occurrence;
  final projectionId = reminderProjectionId(
    userId: context.ownerUserId,
    sessionGeneration: context.accessEpoch,
    occurrenceId: occurrence.id,
    kind: kind,
    workspaceId: context.workspaceId,
    grantEpoch: context.accessEpoch,
    stateVersion: occurrence.stateVersion,
  );
  return {
    ...ProjectionIdentity.fromContext(context).toJson(),
    'userId': context.ownerUserId,
    'sessionGeneration': context.accessEpoch,
    'occurrenceId': occurrence.id,
    'projectionId': projectionId,
    'stateVersion': occurrence.stateVersion,
  };
}

Future<void> _expectNoCareMutation(CareRecordingFixture fixture) async {
  final occurrence = await fixture.db.medicationLedgerDao.getOccurrenceById(
    fixture.occurrence.id,
  );
  expect(occurrence?.state, 'pending');
  expect(
    await fixture.db.medicationLedgerDao.getEventsForOccurrence(
      fixture.occurrence.id,
    ),
    isEmpty,
  );
  expect(await fixture.db.select(fixture.db.pendingOperations).get(), isEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'notification review loads a cold named zone without recording care',
    () async {
      final fixture = await _fictionalFixture();
      addTearDown(fixture.db.close);
      final payload = _protectedPayload(fixture, kind: 'reminder');
      final raw = jsonEncode(payload);
      tz.timeZoneDatabase.clear();
      expect(tz.timeZoneDatabase.isInitialized, isFalse);

      final occurrenceId = await validateNotificationActionForReview(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: raw,
        ),
        db: fixture.db,
        access: fixture.workspace.access,
      );

      expect(occurrenceId, fixture.occurrence.id);
      expect(tz.timeZoneDatabase.isInitialized, isTrue);
      expect(tz.getLocation('Europe/Bucharest').name, 'Europe/Bucharest');
      await _expectNoCareMutation(fixture);
    },
  );

  test(
    'widget review loads a cold named zone without recording care',
    () async {
      final fixture = await _fictionalFixture();
      addTearDown(fixture.db.close);
      final payload = _protectedPayload(fixture, kind: 'widget');
      final uri = Uri(
        scheme: 'simpastil',
        host: 'take',
        queryParameters: {
          'active_user_id': payload['userId']! as String,
          'session_generation': '${payload['sessionGeneration']}',
          'occurrenceId': payload['occurrenceId']! as String,
          'projectionId': payload['projectionId']! as String,
          'version': '2',
          'workspaceId': payload['workspaceId']! as String,
          'grantEpoch': '${payload['grantEpoch']}',
          'stateVersion': '${payload['stateVersion']}',
        },
      );
      tz.timeZoneDatabase.clear();
      expect(tz.timeZoneDatabase.isInitialized, isFalse);

      final occurrenceId = await validateWidgetActionForReview(
        uri,
        db: fixture.db,
        access: fixture.workspace.access,
      );

      expect(occurrenceId, fixture.occurrence.id);
      expect(tz.timeZoneDatabase.isInitialized, isTrue);
      expect(tz.getLocation('Europe/Bucharest').name, 'Europe/Bucharest');
      await _expectNoCareMutation(fixture);
    },
  );
}
