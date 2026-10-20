import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';

import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/held_provider_read.dart';

const _reviewId = 'fictional-account-review';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'review snapshot reads under the live captured grant without prewarming',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create();
      await _recordIssue(fixture.db, fixture.context.ownerUserId);
      final container = await _containerFor(
        fixture,
        Stream.value(fixture.context),
      );
      addTearDown(() async {
        container.dispose();
        await fixture.db.close();
      });

      // Deliberately do not read a related provider first. The review snapshot
      // must finish with its own captured context and guarded read.
      final reviews = await container
          .readHeld(migrationIssuesProvider)
          .timeout(const Duration(seconds: 5));

      expect(reviews.map((review) => review.id), [_reviewId]);
    },
  );

  test(
    'a revoked captured grant refuses the account-wide review read',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create();
      await _recordIssue(fixture.db, fixture.context.ownerUserId);
      await (fixture.db.update(fixture.db.workspaceGrants)..where(
            (row) => row.workspaceId.equals(fixture.context.workspaceId),
          ))
          .write(const WorkspaceGrantsCompanion(isGranted: Value(false)));
      final container = await _containerFor(
        fixture,
        Stream.value(fixture.context),
      );
      addTearDown(() async {
        container.dispose();
        await fixture.db.close();
      });

      await expectLater(
        container.readHeld(migrationIssuesProvider),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
    },
  );

  test(
    'same-owner epoch replacement invalidates and reloads the review',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create();
      await _recordIssue(fixture.db, fixture.context.ownerUserId);
      final contexts = StreamController<WorkspaceContext>();
      final container = await _containerFor(fixture, contexts.stream);
      addTearDown(() async {
        await contexts.close();
        container.dispose();
        await fixture.db.close();
      });

      final contextReady = container.readHeld(workspaceContextProvider);
      contexts.add(fixture.context);
      expect(await contextReady, fixture.context);

      final nextReview = Completer<List<MigrationIssueSummary>>();
      var awaitingReplacement = false;
      final replacementContext = Completer<WorkspaceContext>();
      final contextSubscription = container.listen(workspaceContextProvider, (
        _,
        state,
      ) {
        final context = state.asData?.value;
        if (context?.accessEpoch == fixture.context.accessEpoch + 1 &&
            !replacementContext.isCompleted) {
          replacementContext.complete(context!);
        }
      }, fireImmediately: true);
      addTearDown(contextSubscription.close);
      final subscription = container.listen(migrationIssuesProvider, (
        _,
        state,
      ) {
        if (!awaitingReplacement || state.isLoading || state.hasError) return;
        final reviews = state.asData?.value;
        if (awaitingReplacement && reviews != null && !nextReview.isCompleted) {
          nextReview.complete(reviews);
        }
      }, fireImmediately: true);
      addTearDown(subscription.close);

      final initial = await container
          .readHeld(migrationIssuesProvider)
          .timeout(const Duration(seconds: 5));
      expect(initial.map((review) => review.id), [_reviewId]);

      final nextEpoch = fixture.context.accessEpoch + 1;
      await (fixture.db.update(fixture.db.workspaceGrants)..where(
            (row) => row.workspaceId.equals(fixture.context.workspaceId),
          ))
          .write(WorkspaceGrantsCompanion(epoch: Value(nextEpoch)));
      final replacement = await fixture.access.contextForOwner(
        fixture.context.ownerUserId,
      );
      expect(replacement, isNotNull);
      expect(replacement!.ownerUserId, fixture.context.ownerUserId);
      expect(replacement.workspaceId, fixture.context.workspaceId);
      expect(replacement.accessEpoch, nextEpoch);

      awaitingReplacement = true;
      contexts.add(replacement);
      expect(await replacementContext.future, replacement);
      final reloaded = await nextReview.future.timeout(
        const Duration(seconds: 5),
      );
      expect(reloaded.map((review) => review.id), [_reviewId]);
    },
  );

  test(
    'late old-grant result cannot replace the newer review snapshot',
    () async {
      late final _DelayedWorkspaceAccess delayedAccess;
      final fixture = await ProtectedWorkspaceFixture.create(
        accessFactory: (database) =>
            delayedAccess = _DelayedWorkspaceAccess(database),
      );
      await _recordIssue(fixture.db, fixture.context.ownerUserId);
      final contexts = StreamController<WorkspaceContext>();
      final container = await _containerFor(fixture, contexts.stream);
      addTearDown(() async {
        await contexts.close();
        container.dispose();
        await fixture.db.close();
      });

      final contextReady = container.readHeld(workspaceContextProvider);
      contexts.add(fixture.context);
      expect(await contextReady, fixture.context);

      final revisions = <int>[];
      final freshReview = Completer<List<MigrationIssueSummary>>();
      final oldResultReady = Completer<void>();
      final releaseOldResult = Completer<void>();
      final oldResultReturned = Completer<void>();
      delayedAccess.holdNextResult(
        oldResultReady,
        releaseOldResult,
        oldResultReturned,
      );
      final subscription = container.listen(migrationIssuesProvider, (
        _,
        state,
      ) {
        if (state.isLoading || state.hasError) return;
        final reviews = state.asData?.value;
        if (reviews == null) return;
        revisions.add(reviews.single.revision);
        if (reviews.single.revision == 2 && !freshReview.isCompleted) {
          freshReview.complete(reviews);
        }
      }, fireImmediately: true);
      addTearDown(subscription.close);
      await oldResultReady.future.timeout(const Duration(seconds: 5));

      final nextEpoch = fixture.context.accessEpoch + 1;
      await fixture.db.transaction(() async {
        await (fixture.db.update(fixture.db.workspaceGrants)..where(
              (row) => row.workspaceId.equals(fixture.context.workspaceId),
            ))
            .write(WorkspaceGrantsCompanion(epoch: Value(nextEpoch)));
        await (fixture.db.update(
          fixture.db.migrationIssues,
        )..where((row) => row.id.equals(_reviewId))).write(
          MigrationIssuesCompanion(
            revision: const Value(2),
            snapshotJson: const Value('{"syntheticRevision":2}'),
            updatedAt: Value(DateTime.utc(2026, 10, 10)),
          ),
        );
      });
      final replacement = await fixture.access.contextForOwner(
        fixture.context.ownerUserId,
      );
      expect(replacement, isNotNull);
      expect(replacement!.accessEpoch, nextEpoch);
      contexts.add(replacement);

      final fresh = await freshReview.future.timeout(
        const Duration(seconds: 5),
      );
      expect(fresh.single.revision, 2);

      releaseOldResult.complete();
      await oldResultReturned.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(revisions, isNot(contains(1)));
      expect(revisions.last, 2);
    },
  );
}

Future<void> _recordIssue(AppDatabase db, String ownerId) async {
  final now = DateTime.utc(2026, 10, 9);
  await db.migrationIssuesDao.record(
    MigrationIssuesCompanion.insert(
      id: _reviewId,
      userId: ownerId,
      entityType: 'unknown',
      entityId: 'fictional-record',
      issueCode: 'sync_item_needs_review',
      snapshotJson: '{}',
      createdAt: now,
      updatedAt: now,
    ),
  );
}

Future<ProviderContainer> _containerFor(
  ProtectedWorkspaceFixture fixture,
  Stream<WorkspaceContext> contexts,
) async {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      ...fixture.overrides,
      workspaceContextProvider.overrideWith((ref) => contexts),
    ],
  );
  return container;
}

class _DelayedWorkspaceAccess extends WorkspaceAccessRepository {
  _DelayedWorkspaceAccess(super.database);

  Completer<void>? _resultReady;
  Completer<void>? _releaseResult;
  Completer<void>? _resultReturned;

  void holdNextResult(
    Completer<void> resultReady,
    Completer<void> releaseResult,
    Completer<void> resultReturned,
  ) {
    _resultReady = resultReady;
    _releaseResult = releaseResult;
    _resultReturned = resultReturned;
  }

  @override
  Future<T> withGrant<T>(
    WorkspaceContext context,
    Future<T> Function() action, {
    String? profileId,
  }) async {
    final result = await super.withGrant(context, action, profileId: profileId);
    final resultReady = _resultReady;
    final releaseResult = _releaseResult;
    final resultReturned = _resultReturned;
    if (resultReady != null &&
        releaseResult != null &&
        resultReturned != null) {
      _resultReady = null;
      _releaseResult = null;
      _resultReturned = null;
      resultReady.complete();
      await releaseResult.future;
      resultReturned.complete();
    }
    return result;
  }
}
