import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/profiles_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _ownerId = '10000000-0000-4000-8000-000000000301';
const _profileId = '10000000-0000-4000-8000-000000000302';
const _mutationId = '10000000-0000-4000-8000-000000000303';
final _createdAt = DateTime.utc(2026, 10, 12, 8);

class _Harness {
  _Harness(this.workspace, this.adapter, this.requests, this.respond);
  final ProtectedWorkspaceFixture workspace;
  final V2StableAdapter adapter;
  final List<RequestOptions> requests;
  void Function(RequestOptions, RequestInterceptorHandler) respond;

  AppDatabase get db => workspace.db;

  Future<PendingOperation> op() async =>
      (await db.pendingOperationsDao.getForUser(_ownerId)).single;

  Future<SyncComponentOutcome> flush() =>
      ProfilesSyncAdapter(db).flush(_ownerId, adapter);

  /// Moves the last attempt far enough back that any backoff has elapsed.
  Future<void> elapseBackoff() async {
    await (db.update(db.pendingOperations)).write(
      PendingOperationsCompanion(
        lastAttemptAt: Value(
          DateTime.now().toUtc().subtract(const Duration(days: 1)),
        ),
      ),
    );
  }
}

Future<_Harness> _harness({
  required String action,
  int revision = 0,
  String? serverId,
}) async {
  final workspace = await ProtectedWorkspaceFixture.create(ownerId: _ownerId);
  addTearDown(workspace.db.close);
  await workspace.db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: _profileId,
      userId: _ownerId,
      name: 'Fictional person',
      createdAt: _createdAt,
      updatedAt: _createdAt,
      serverId: Value(serverId),
      revision: Value(revision),
      syncStatus: Value(serverId == null ? 'pending' : 'synced'),
    ),
  );
  await PendingOperationRepository(
    workspace.db,
    access: workspace.access,
    context: workspace.context,
  ).record(
    operation: PendingOperationDraft(
      userId: _ownerId,
      mutationId: _mutationId,
      operationType: 'profile.$action',
      entityType: 'profile',
      entityLocalId: _profileId,
      payload: {
        'action': action,
        'data': action == 'delete'
            ? const <String, Object?>{}
            : const {'name': 'Fictional person', 'avatarEmoji': 'x'},
      },
    ),
    applyProjection: () async {},
  );
  final requests = <RequestOptions>[];
  late _Harness harness;
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        harness.respond(options, handler);
      },
    ),
  );
  final adapter = V2StableAdapter(
    db: workspace.db,
    dio: dio,
    writeScope: SyncWriteScope(
      access: workspace.access,
      capability: await workspace.access.currentNetworkCapability(),
    ),
  );
  harness = _Harness(workspace, adapter, requests, (_, _) {});
  return harness;
}

void Function(RequestOptions, RequestInterceptorHandler) _status(
  int? status, {
  Map<String, String> headers = const {},
  Map<String, Object?>? error,
}) => (request, handler) {
  handler.reject(
    DioException(
      requestOptions: request,
      type: status == null
          ? DioExceptionType.receiveTimeout
          : DioExceptionType.badResponse,
      response: status == null
          ? null
          : Response(
              requestOptions: request,
              statusCode: status,
              headers: Headers.fromMap({
                for (final e in headers.entries) e.key: [e.value],
              }),
              data: error == null ? null : {'error': error},
            ),
    ),
  );
};

void _ok(RequestOptions request, RequestInterceptorHandler handler) {
  handler.resolve(
    Response(
      requestOptions: request,
      statusCode: 201,
      data: {'id': _profileId, 'revision': '1'},
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final entry in <String, int?>{
    'timeout without a response': null,
    '500': 500,
    '503': 503,
    '408': 408,
    '429': 429,
  }.entries) {
    test('${entry.key} is retryable and replays the identical body', () async {
      final h = await _harness(action: 'create');
      h.respond = _status(entry.value);

      final outcome = await h.flush();

      var op = await h.op();
      expect(op.state, 'failedRetryable');
      expect(op.attemptCount, 1);
      expect(outcome.status, SyncComponentStatus.partiallySynced);
      expect(h.requests, hasLength(1));

      // Still inside the backoff window: no request leaves the phone.
      await h.flush();
      expect(h.requests, hasLength(1));
      expect((await h.op()).attemptCount, 1);

      h.respond = _ok;
      await h.elapseBackoff();
      final second = await h.flush();

      expect(second.status, SyncComponentStatus.succeeded);
      expect(h.requests, hasLength(2));
      expect(h.requests.last.data, h.requests.first.data);
      expect((h.requests.last.data as Map)['mutationId'], _mutationId);
      op = await h.op();
      expect(op.state, 'committed');
      expect(op.attemptCount, 2, reason: 'attempts are never reset');
    });
  }

  test('Retry-After pushes the next attempt out', () async {
    final h = await _harness(action: 'create');
    h.respond = _status(429, headers: {'retry-after': '7200'});

    await h.flush();

    final op = await h.op();
    expect(op.state, 'failedRetryable');
    expect(
      op.lastAttemptAt!.isAfter(DateTime.now().toUtc()),
      isTrue,
      reason: 'the effective attempt time includes the server request',
    );
    h.respond = _ok;
    await h.flush();
    expect(h.requests, hasLength(1), reason: 'still inside Retry-After');
  });

  test('the attempt cap blocks with a safe code and a review issue', () async {
    final h = await _harness(action: 'create');
    h.respond = _status(500);
    await (h.db.update(
      h.db.pendingOperations,
    )).write(const PendingOperationsCompanion(attemptCount: Value(7)));

    await h.flush();

    final op = await h.op();
    expect(op.attemptCount, 8);
    expect(op.state, 'blocked');
    expect(op.safeErrorCode, 'SYNC_RETRY_EXHAUSTED');
    final issues = await h.db.select(h.db.migrationIssues).get();
    expect(issues.map((i) => i.issueCode), ['sync_retry_exhausted']);
    expect(issues.single.entityId, op.id);
  });

  test(
    'a body that changed since the first send is blocked, not sent',
    () async {
      final h = await _harness(
        action: 'update',
        revision: 3,
        serverId: _profileId,
      );
      h.respond = _status(500);
      await h.flush();
      expect(h.requests, hasLength(1));
      expect((h.requests.single.data as Map)['baseRevision'], '3');

      // Something moved the revision between attempts.
      await (h.db.update(
        h.db.profiles,
      )).write(const ProfilesCompanion(revision: Value(4)));
      await h.elapseBackoff();
      h.respond = _ok;
      await h.flush();

      expect(
        h.requests,
        hasLength(1),
        reason: 'a different body is never sent',
      );
      final op = await h.op();
      expect(op.state, 'blocked');
      expect(op.safeErrorCode, 'STABLE_REQUEST_BODY_CHANGED');
    },
  );

  test('the body is frozen at the first send, not before', () async {
    final h = await _harness(action: 'create');
    expect(
      jsonDecode((await h.op()).payloadJson),
      isNot(contains('frozenRequest')),
    );
    h.respond = _status(500);
    await h.flush();
    final payload = jsonDecode((await h.op()).payloadJson) as Map;
    expect(payload['frozenRequest'], isA<Map>());
    expect((payload['frozenRequest'] as Map)['body'], h.requests.single.data);
  });

  test(
    'a crash while sending requeues the op and replays the same body',
    () async {
      final h = await _harness(action: 'create');
      h.respond = _status(500);
      await h.flush();
      final firstBody = h.requests.single.data;
      // Simulate the process dying after the claim of the second attempt.
      await (h.db.update(
        h.db.pendingOperations,
      )).write(const PendingOperationsCompanion(state: Value('sending')));

      final recovered = await h.db.pendingOperationsDao
          .recoverInterruptedOperations(userId: _ownerId);

      expect(recovered, 1);
      expect((await h.op()).state, 'queued');
      expect(await h.db.select(h.db.migrationIssues).get(), isEmpty);
      h.respond = _ok;
      await h.flush();
      expect(h.requests, hasLength(2));
      expect(h.requests.last.data, firstBody);
      expect((await h.op()).state, 'committed');
    },
  );

  test('a crash with no frozen body (pre-upgrade op) stays blocked', () async {
    final h = await _harness(action: 'create');
    await (h.db.update(
      h.db.pendingOperations,
    )).write(const PendingOperationsCompanion(state: Value('sending')));

    await h.db.pendingOperationsDao.recoverInterruptedOperations(
      userId: _ownerId,
    );

    expect((await h.op()).state, 'blocked');
    expect(await h.db.select(h.db.migrationIssues).get(), hasLength(1));
  });

  test(
    '"awaiting reconciliation" 409 is blocked, not a user conflict',
    () async {
      final h = await _harness(action: 'create');
      h.respond = _status(
        409,
        error: {
          'code': 'CONFLICT_REVISION',
          'message': 'Bridge command is awaiting reconciliation',
          'retryable': false,
        },
      );

      await h.flush();

      final op = await h.op();
      expect(op.state, 'blocked');
      expect(op.safeErrorCode, 'SPLIT_RECONCILIATION_REQUIRED');
    },
  );

  test('a real revision conflict is still a conflict', () async {
    final h = await _harness(action: 'create');
    h.respond = _status(
      409,
      error: {
        'code': 'CONFLICT_REVISION',
        'message': 'Revision mismatch',
        'retryable': false,
      },
    );

    await h.flush();

    expect((await h.op()).state, 'conflict');
  });
}
