import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/backup_manifest.dart';
import 'package:simpastil/core/backup/backup_service.dart';

void main() {
  test('Full archive retains orphan history without assigning an owner', () {
    final tables = <String, List<Map<String, Object?>>>{
      'users': [
        {'id': 'owner'},
      ],
      'dose_logs': [
        {'id': 'old-dose', 'schedule_id': 'deleted-schedule'},
      ],
      'sync_staging_items': [
        {
          'run_id': 'deleted-run',
          'server_sequence': 1,
          'entity_type': 'bridge_dose',
          'entity_id': 'old-dose',
          'payload_json': jsonEncode({
            'payload': {
              'kind': 'bridgeDose',
              'id': 'old-dose',
              'scheduleId': 'deleted-schedule',
            },
          }),
        },
      ],
    };
    expect(
      () => BackupOwnership.validate(tables, {'owner'}),
      throwsA(isA<BackupFailure>()),
    );
    final proven = BackupOwnership.validate(tables, {
      'owner',
    }, allowUnattributedHistory: true);
    expect(proven, hasLength(1));
    expect(proven.values.single, 'owner');
    expect(tables['dose_logs'], hasLength(1));
  });

  test('nested historical ancestor owners are checked before archival', () {
    for (final owner in ['foreign-owner', 'owner']) {
      final tables = <String, List<Map<String, Object?>>>{
        'profiles': [
          {'id': 'person', 'user_id': 'other-owner'},
        ],
        'sync_staging_items': [
          {
            'run_id': 'deleted-run',
            'server_sequence': 1,
            'entity_type': 'bridge_dose',
            'entity_id': 'old-dose',
            'payload_json': jsonEncode({
              'payload': {
                'kind': 'bridgeDose',
                'id': 'old-dose',
                'scheduleId': 'schedule',
                'parentSchedule': {'id': 'schedule', 'pillId': 'pill'},
                'parentPill': {'id': 'pill', 'profileId': 'person'},
                'parentProfile': {'id': 'person', 'userId': owner},
              },
            }),
          },
        ],
      };
      expect(
        () => BackupOwnership.validate(tables, {
          'owner',
          'other-owner',
        }, allowUnattributedHistory: true),
        throwsA(isA<BackupFailure>()),
      );
    }
  });

  test(
    'archival exception refuses foreign payload owners and unknown payloads',
    () {
      for (final payload in [
        {'kind': 'profile', 'id': 'foreign-person', 'userId': 'foreign-owner'},
        {'kind': 'unrecognized'},
      ]) {
        final tables = <String, List<Map<String, Object?>>>{
          'sync_staging_items': [
            {
              'run_id': 'deleted-run',
              'server_sequence': 1,
              'entity_type': 'profile',
              'entity_id': 'foreign-person',
              'payload_json': jsonEncode({'payload': payload}),
            },
          ],
        };
        expect(
          () => BackupOwnership.validate(tables, {
            'owner',
          }, allowUnattributedHistory: true),
          throwsA(isA<BackupFailure>()),
        );
      }
    },
  );
}
