import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/api/scoped_access_error.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/sync_coordinator.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/utils/safe_diagnostics.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: 'user-1',
            email: 'user@test.com',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
  });

  tearDown(() => db.close());

  test(
    'access refusal reports its stage without swallowing the guard',
    () async {
      final messages = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = originalPrint);
      const refusal = WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.wrongPerson,
      );

      await expectLater(
        SyncCoordinator(db).run(
          userId: 'user-1',
          stages: [
            SyncStage(
              id: 'stable',
              component: SyncComponent.stable,
              contractVersion: 2,
              run: () async => throw refusal,
            ),
          ],
        ),
        throwsA(same(refusal)),
      );
      final diagnostics = messages.where((line) => line.contains('[SyncDiag]'));
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single, contains('"component":"stable"'));
      expect(diagnostics.single, contains('"reason":"wrongPerson"'));
      expect(diagnostics.single, isNot(contains('user-1')));
    },
  );

  test(
    'local protected access refusal is preserved as a safe sync cause',
    () async {
      final result = await SyncCoordinator(db).run(
        userId: 'user-1',
        stages: [
          SyncStage(
            id: 'account',
            component: SyncComponent.account,
            contractVersion: 1,
            run: () async => throw DioException(
              requestOptions: RequestOptions(path: '/sync/account'),
              type: DioExceptionType.cancel,
              message: scopedAccessUnavailableMessage,
            ),
          ),
        ],
      );

      expect(
        result.forStage('account')?.safeErrorCode,
        'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
      );
      expect(result.forStage('account')?.httpStatusCode, isNull);
    },
  );

  test(
    'caught bridge failure is diagnosable without exposing care or advancing its checkpoint',
    () async {
      final previousSuccess = DateTime.utc(2026, 1, 1);
      await db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: 'user-1',
          component: 'medicationBridge',
          contractVersion: 3,
          lastCompletedCursor: const Value('19'),
          lastFullSuccessAt: Value(previousSuccess),
        ),
      );
      final messages = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = originalPrint);

      final result = await SyncCoordinator(db).run(
        userId: 'user-1',
        stages: [
          SyncStage(
            id: 'medicationBridge',
            component: SyncComponent.medicationBridge,
            contractVersion: 3,
            run: () async => Error.throwWithStackTrace(
              const FormatException('private-medication private-owner'),
              StackTrace.fromString(
                '#0 merge (package:simpastil/core/sync/component_sync_merger.dart:420:7)\n'
                '#1 /private-device/private-person.dart:3:1',
              ),
            ),
          ),
        ],
      );

      expect(
        result.forStage('medicationBridge')?.status,
        SyncComponentStatus.failed,
      );
      final state = await db.syncStateDao.getState(
        'user-1',
        'medicationBridge',
      );
      expect(state?.lastCompletedCursor, '19');
      expect(state?.lastFullSuccessAt?.toUtc(), previousSuccess);
      final diagnostics = messages.where((line) => line.contains('[SyncDiag]'));
      expect(diagnostics, hasLength(1));
      final event =
          jsonDecode(diagnostics.single.split('[SyncDiag] ').last) as Map;
      expect(event['event'], 'sync_stage_failed');
      expect(event['component'], 'medicationBridge');
      expect(event['category'], 'format');
      expect(event['phase'], 'stage_run');
      expect(
        event.keys,
        unorderedEquals(['event', 'component', 'phase', 'category']),
      );
      expect(event.toString(), isNot(contains('private')));
      expect(event.toString(), isNot(contains('user-1')));
      expect(state?.diagnosticMetadataJson, isNot(contains('private')));
    },
  );

  test(
    'SQLite stage diagnosis excludes messages, SQL and bound values',
    () async {
      final messages = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = originalPrint);

      final result = await SyncCoordinator(db).run(
        userId: 'user-1',
        stages: [
          SyncStage(
            id: 'medicationBridge',
            component: SyncComponent.medicationBridge,
            contractVersion: 3,
            run: () async => Error.throwWithStackTrace(
              SqliteException(
                extendedResultCode: 787,
                message: 'private-medication',
                causingStatement:
                    'INSERT INTO "pills" ("name") VALUES (\'private-note\')',
                parametersToStatement: const ['private-owner', 'private-token'],
                explanation: 'private-care-description',
              ),
              StackTrace.fromString(
                '#0 /private-device/private-person.dart:3:1',
              ),
            ),
          ),
        ],
      );

      expect(
        result.forStage('medicationBridge')?.status,
        SyncComponentStatus.failed,
      );
      final diagnostics = messages.where((line) => line.contains('[SyncDiag]'));
      expect(diagnostics, hasLength(1));
      final event =
          jsonDecode(diagnostics.single.split('[SyncDiag] ').last) as Map;
      expect(event['category'], 'sqlite');
      expect(event['sqliteCode'], 19);
      expect(event['sqliteExtendedCode'], 787);
      expect(event['phase'], 'stage_run');
      expect(
        event.keys,
        unorderedEquals([
          'event',
          'component',
          'phase',
          'category',
          'sqliteCode',
          'sqliteExtendedCode',
        ]),
      );
      expect(event.toString(), isNot(contains('private')));
      expect(event.toString(), isNot(contains('INSERT')));
      expect(event.toString(), isNot(contains('user-1')));
    },
  );

  test(
    'independent stages continue and dependent stages are explicitly blocked',
    () async {
      var dependentRan = false;
      final result = await SyncCoordinator(db).run(
        userId: 'user-1',
        stages: [
          SyncStage(
            id: 'stable',
            component: SyncComponent.stable,
            contractVersion: 2,
            run: () async => const SyncComponentOutcome.succeeded(),
          ),
          SyncStage(
            id: 'medication',
            component: SyncComponent.medication,
            contractVersion: 2,
            run: () async => const SyncComponentOutcome.failed(
              safeErrorCode: 'MEDICATION_REJECTED',
            ),
          ),
          SyncStage(
            id: 'medication-child',
            component: SyncComponent.medication,
            contractVersion: 2,
            dependsOn: const ['medication'],
            run: () async {
              dependentRan = true;
              return const SyncComponentOutcome.succeeded();
            },
          ),
        ],
      );

      expect(dependentRan, isFalse);
      expect(result.status, SyncRunStatus.partiallySynced);
      expect(
        result.forStage('medication-child')?.status,
        SyncComponentStatus.blocked,
      );
      final state = await db.syncStateDao.getState('user-1', 'medication');
      expect(state?.diagnosticMetadataJson, isNot(contains('payload')));
      expect(
        state?.diagnosticMetadataJson,
        isNot(contains('MEDICATION_REJECTED')),
      );
    },
  );

  test(
    'the medication-details replay marker survives a stage outcome',
    () async {
      await db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: 'user-1',
          component: 'stable',
          contractVersion: 2,
          diagnosticMetadataJson: Value(
            jsonEncode({'projectionRevision': 'medication-details-v1'}),
          ),
        ),
      );
      await SyncCoordinator(db).run(
        userId: 'user-1',
        stages: [
          SyncStage(
            id: 'stable',
            component: SyncComponent.stable,
            contractVersion: 2,
            run: () async => const SyncComponentOutcome.succeeded(),
          ),
        ],
      );
      final state = await db.syncStateDao.getState('user-1', 'stable');
      expect(
        jsonDecode(state!.diagnosticMetadataJson!)['projectionRevision'],
        'medication-details-v1',
      );
    },
  );

  test('diagnostics map identifiers and routes to bounded safe values', () {
    final diagnostic = SafeDiagnostics.httpEvent(
      event: 'http_failed',
      path: '/profiles/secret-user/pills/secret-pill',
      statusCode: 409,
      duration: const Duration(seconds: 9),
      correlationId: 'not-a-correlation-id-with-sensitive-value',
      retryCount: 80,
      clientBuild: 2,
    );

    expect(diagnostic['route'], '/profiles/:id/pills/:id');
    expect(diagnostic['statusClass'], '4xx');
    expect(diagnostic['durationMs'], 9000);
    expect(diagnostic['retryCount'], 10);
    expect(diagnostic['correlationId'], isNull);
    expect(diagnostic.toString(), isNot(contains('secret')));

    final refusal = SafeDiagnostics.accessRefusalEvent(
      component: 'secret-account',
      entityType: 'secret-medication',
      payloadKind: 'secret-payload',
      phase: 'secret-care-data',
      parentIdentity: 'secret-parent-id',
      legacyOwnerEvidence: 'secret-owner-id',
      reason: 'secret-error-message',
    );
    expect(refusal.toString(), isNot(contains('secret')));
    expect(refusal['component'], 'unknown');
    expect(refusal['entityType'], 'unknown');
    expect(refusal['payloadKind'], 'unknown');
    expect(refusal['reason'], 'unknown');
    expect(refusal['phase'], 'unknown');
    expect(refusal['parentIdentity'], 'unknown');
    expect(refusal['legacyOwnerEvidence'], 'unknown');

    final connectionRefusal = SafeDiagnostics.connectionAccessRefusalEvent(
      path: '/sync/account/private-owner',
      reason: 'network_scope_stale',
    );
    expect(connectionRefusal, {
      'event': 'connection_access_refused',
      'route': '/sync/:component',
      'reason': 'network_scope_stale',
    });
    final unknownConnectionRefusal =
        SafeDiagnostics.connectionAccessRefusalEvent(
          path: 'https://private.example/private-path',
          reason: 'private-canary',
        );
    expect(unknownConnectionRefusal, {
      'event': 'connection_access_refused',
      'route': '/other',
      'reason': 'access_check_failed',
    });
  });
}
