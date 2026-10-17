import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/storage/preference_keys.dart';

void main() {
  test(
    'protected projection identity requires the delivered state version',
    () {
      expect(
        () => widgetProjectionCanonicalKey(
          userId: '00000000-0000-4000-8000-000000000001',
          sessionGeneration: 3,
          occurrenceId: '00000000-0000-4000-8000-000000000002',
          kind: 'widget',
          workspaceId: '00000000-0000-4000-8000-000000000003',
          grantEpoch: 3,
        ),
        throwsArgumentError,
      );
    },
  );
  test('automatic miss command IDs match the shared v3 fixture', () {
    final fixture =
        jsonDecode(
              File(
                '../contracts/fixtures/projection-command-ids-v3.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(fixture['version'], 3);
    final vectors = fixture['autoMissVectors'] as List<dynamic>;
    expect(vectors, isNotEmpty);
    for (final vector in vectors) {
      final item = vector as Map<String, dynamic>;
      final key = autoMissCommandKey(
        ownerUserId: item['ownerUserId'] as String,
        occurrenceKey: item['occurrenceKey'] as String,
      );
      expect(key, item['canonicalKey']);
      expect(
        autoMissCommandId(
          ownerUserId: item['ownerUserId'] as String,
          occurrenceKey: item['occurrenceKey'] as String,
        ),
        item['commandId'],
      );
    }
  });

  test('an automatic miss command ID does not depend on the install', () {
    const owner = '00000000-0000-4000-8000-000000000001';
    const key =
        'scheduled:v1:abababababababababababababababababababababababababababababababab';
    // The workspace ID is minted per install, so it is not an input at all:
    // every device of one account derives the same ID for one occurrence.
    expect(
      autoMissCommandId(ownerUserId: owner, occurrenceKey: key),
      autoMissCommandId(ownerUserId: owner, occurrenceKey: key),
    );
    expect(
      autoMissCommandId(ownerUserId: owner, occurrenceKey: key),
      isNot(
        autoMissCommandId(
          ownerUserId: '00000000-0000-4000-8000-000000000002',
          occurrenceKey: key,
        ),
      ),
    );
    expect(
      autoMissCommandId(ownerUserId: owner, occurrenceKey: key),
      isNot(autoMissCommandId(ownerUserId: owner, occurrenceKey: '$key-2')),
    );
  });

  test('matches the versioned cross-runtime command ID fixture', () {
    final fixture =
        jsonDecode(
              File(
                '../contracts/fixtures/projection-command-ids-v1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(fixture['version'], 1);
    for (final vector in fixture['vectors'] as List<dynamic>) {
      final item = vector as Map<String, dynamic>;
      expect(
        projectionCommandIdForKey(item['canonicalKey'] as String),
        item['commandId'],
      );
    }

    final projection = fixture['widgetProjection'] as Map<String, dynamic>;
    expect(
      widgetProjectionCanonicalKey(
        userId: projection['userId'] as String,
        sessionGeneration: projection['sessionGeneration'] as int,
        occurrenceId: projection['occurrenceId'] as String,
        kind: projection['kind'] as String,
      ),
      projection['canonicalKey'],
    );

    final actionVectors = fixture['widgetActionVectors'] as List<dynamic>;
    final commandIds = <String>[];
    for (final vector in actionVectors) {
      final item = vector as Map<String, dynamic>;
      final key = widgetActionCommandKey(
        projectionId: item['projectionId'] as String,
        occurrenceId: item['occurrenceId'] as String,
        action: item['action'] as String,
      );
      expect(key, item['canonicalKey']);
      commandIds.add(
        widgetActionCommandId(
          projectionId: item['projectionId'] as String,
          occurrenceId: item['occurrenceId'] as String,
          action: item['action'] as String,
        ),
      );
    }
    expect(commandIds, hasLength(2));
    expect(commandIds.first, isNot(commandIds.last));

    final keys = fixture['preferenceKeys'] as Map<String, dynamic>;
    expect(kTodayDosesKey, keys['todayDoses']);
    expect(kSnapshotDayKey, keys['snapshotDay']);
    expect(kAppThemeModeKey, keys['appThemeMode']);
    expect(kActiveUserIdKey, keys['activeUserId']);
    expect(kSessionGenerationKey, keys['sessionGeneration']);
    expect(prnInStatsPreferenceKey('user-1'), 'prn_in_stats_user-1');
    expect(prnInWidgetPreferenceKey('user-1'), 'prn_in_widget_user-1');
  });

  test(
    'version2 native vectors bind workspace and grant without changing action IDs',
    () {
      final fixture =
          jsonDecode(
                File(
                  '../contracts/fixtures/projection-command-ids-v2.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(fixture['version'], 2);
      for (final item in fixture['widgetProjectionVectors'] as List) {
        final projectionId = widgetProjectionId(
          userId: item['userId'] as String,
          sessionGeneration: item['grantEpoch'] as int,
          occurrenceId: item['occurrenceId'] as String,
          workspaceId: item['workspaceId'] as String,
          grantEpoch: item['grantEpoch'] as int,
          stateVersion: item['stateVersion'] as int,
        );
        expect(
          widgetProjectionCanonicalKey(
            userId: item['userId'] as String,
            sessionGeneration: item['grantEpoch'] as int,
            occurrenceId: item['occurrenceId'] as String,
            workspaceId: item['workspaceId'] as String,
            grantEpoch: item['grantEpoch'] as int,
            stateVersion: item['stateVersion'] as int,
            kind: 'widget',
          ),
          item['canonicalKey'],
        );
        expect(projectionId, item['projectionId']);
        for (final action in ['take', 'skip']) {
          expect(
            widgetActionCommandId(
              projectionId: projectionId,
              occurrenceId: item['occurrenceId'] as String,
              action: action,
            ),
            item['${action}CommandId'],
          );
        }
      }
    },
  );

  test('widget and notification replays derive one logical command ID', () {
    const inputs = ProjectionCommandIdentity(
      userId: '00000000-0000-4000-8000-000000000001',
      occurrenceId: '00000000-0000-4000-8000-000000000002',
      action: 'take',
      actualAt: '2026-09-24T05:17:00.000Z',
      note: null,
    );
    const replay = ProjectionCommandIdentity(
      userId: '00000000-0000-4000-8000-000000000001',
      occurrenceId: '00000000-0000-4000-8000-000000000002',
      action: 'take',
      actualAt: '2026-09-24T05:17:00.000Z',
      note: null,
    );
    expect(
      inputs.canonicalKey,
      '[1,"00000000-0000-4000-8000-000000000001",'
      '"00000000-0000-4000-8000-000000000002","take",'
      '"2026-09-24T05:17:00.000Z",null]',
    );
    expect(projectionCommandId(inputs), projectionCommandId(replay));
    expect(
      projectionCommandId(inputs),
      isNot(
        projectionCommandId(
          const ProjectionCommandIdentity(
            userId: '00000000-0000-4000-8000-000000000001',
            occurrenceId: '00000000-0000-4000-8000-000000000002',
            action: 'take',
            actualAt: '2026-09-24T05:17:00.000Z',
            note: 'late',
          ),
        ),
      ),
    );
  });
}
