import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;

import '../db/database.dart';
import '../workspace/workspace_context.dart';
import 'sync_write_scope.dart';
import '../utils/safe_diagnostics.dart';
import 'sync_models.dart';

class SyncCoordinator {
  const SyncCoordinator(this._db, {this.writeScope});

  final AppDatabase _db;
  final SyncWriteScope? writeScope;
  Future<T> _write<T>(Future<T> Function() action) =>
      writeScope?.write(action) ?? _db.transaction(action);

  /// Runs stages in declared order, continues independent work after a stage
  /// fails, and blocks only stages whose explicit dependencies did not finish.
  Future<SyncRunResult> run({
    required String userId,
    required List<SyncStage> stages,
  }) async {
    writeScope?.requireOwner(userId);
    await writeScope?.check();
    final stageIds = stages.map((stage) => stage.id).toSet();
    if (stageIds.length != stages.length) {
      throw ArgumentError('Sync stage IDs must be unique');
    }
    final results = <SyncStageResult>[];
    final outcomesById = <String, SyncComponentOutcome>{};

    for (final stage in stages) {
      final missingDependency = stage.dependsOn.any(
        (dependency) => !stageIds.contains(dependency),
      );
      if (missingDependency) {
        throw ArgumentError('A sync stage depends on an unknown stage');
      }
      final blockedByDependency = stage.dependsOn.any(
        (dependency) => outcomesById[dependency]?.allowsDependents != true,
      );
      if (blockedByDependency) {
        final outcome =
            const SyncComponentOutcome.blocked(
              safeErrorCode: 'SYNC_DEPENDENCY_FAILED',
              retryCount: 0,
            ).withTiming(
              completedAt: DateTime.now().toUtc(),
              duration: Duration.zero,
            );
        await _persist(userId, stage, outcome, Duration.zero);
        outcomesById[stage.id] = outcome;
        results.add(SyncStageResult(stageId: stage.id, outcome: outcome));
        continue;
      }

      final startedAt = DateTime.now().toUtc();
      await _persistRunning(userId, stage);
      late final SyncComponentOutcome outcome;
      try {
        outcome = await stage.run();
      } on DioException catch (error) {
        final retries = error.requestOptions.extra['retryCount'];
        final retryCount = retries is int && retries >= 0 ? retries : 0;
        if (error.response?.statusCode == 401) {
          final elapsed = DateTime.now().toUtc().difference(startedAt);
          await _persist(
            userId,
            stage,
            SyncComponentOutcome.blocked(
              safeErrorCode: 'AUTH_REQUIRED',
              safeCorrelationId: SafeDiagnostics.correlationIdFrom(error),
              httpStatusCode: 401,
              retryCount: retryCount,
            ),
            elapsed,
          );
          rethrow;
        }
        outcome = SyncComponentOutcome.failed(
          safeErrorCode:
              SafeDiagnostics.errorCodeFrom(error) ?? 'SYNC_STAGE_FAILED',
          safeCorrelationId: SafeDiagnostics.correlationIdFrom(error),
          httpStatusCode: error.response?.statusCode,
          retryCount: retryCount,
        );
      } on WorkspaceAccessFailure catch (error) {
        SafeDiagnostics.logAccessRefusal(
          component: stage.component.name,
          reason: error.code.name,
        );
        rethrow;
      } on Object catch (error) {
        SafeDiagnostics.logSyncFailure(
          component: stage.component.name,
          phase: SyncFailurePhase.stageRun,
          error: error,
        );
        outcome = const SyncComponentOutcome.failed(
          safeErrorCode: 'SYNC_STAGE_FAILED',
        );
      }
      final completedAt = DateTime.now().toUtc();
      final elapsed = completedAt.difference(startedAt);
      final observed = outcome.withTiming(
        completedAt: completedAt,
        duration: elapsed,
      );
      await _persist(userId, stage, observed, elapsed);
      outcomesById[stage.id] = observed;
      results.add(SyncStageResult(stageId: stage.id, outcome: observed));
    }
    return SyncRunResult(List.unmodifiable(results));
  }

  Future<void> _persistRunning(String userId, SyncStage stage) async {
    await _write(() async {
      final previous = await _db.syncStateDao.getState(
        userId,
        stage.component.name,
      );
      final sameContract = previous?.contractVersion == stage.contractVersion;
      await _db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: userId,
          component: stage.component.name,
          contractVersion: stage.contractVersion,
          lastCompletedCursor: Value(
            sameContract ? previous?.lastCompletedCursor : null,
          ),
          lastFullSuccessAt: Value(
            sameContract ? previous?.lastFullSuccessAt : null,
          ),
          currentState: const Value('running'),
          diagnosticMetadataJson: Value(previous?.diagnosticMetadataJson),
        ),
      );
    });
  }

  Future<void> _persist(
    String userId,
    SyncStage stage,
    SyncComponentOutcome outcome,
    Duration duration,
  ) async {
    await _write(() async {
      final previous = await _db.syncStateDao.getState(
        userId,
        stage.component.name,
      );
      final sameContract = previous?.contractVersion == stage.contractVersion;
      final now = DateTime.now().toUtc();
      final currentState = switch (outcome.status) {
        SyncComponentStatus.succeeded => 'idle',
        SyncComponentStatus.partiallySynced => 'partial',
        SyncComponentStatus.failed => 'failed',
        SyncComponentStatus.blocked => 'partial',
      };
      final metadata = SafeDiagnostics.stageOutcome(
        stageId: stage.id,
        component: stage.component.name,
        status: outcome.status.name,
        safeCorrelationId: outcome.safeCorrelationId,
        httpStatusCode: outcome.httpStatusCode,
        duration: duration,
      );
      Object? priorMetadata;
      try {
        if (previous?.diagnosticMetadataJson != null) {
          priorMetadata = jsonDecode(previous!.diagnosticMetadataJson!);
        }
      } on FormatException {
        // Malformed prior diagnostics must not obscure the current outcome.
      }
      final projectionRevision = priorMetadata is Map
          ? priorMetadata['projectionRevision']
          : null;
      // Keep the completed projection marker so its recovery replay runs once.
      // Other prior diagnostic fields remain subject to the fixed allowlist.
      if (projectionRevision is String &&
          const {
            'schedule-zone-v1',
            'medication-details-v1',
            'stable-pending-settle-v1',
            'recorded-occurrence-link-v1',
          }.contains(projectionRevision)) {
        metadata['projectionRevision'] = projectionRevision;
      }
      await _db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: userId,
          component: stage.component.name,
          contractVersion: stage.contractVersion,
          lastCompletedCursor: Value(
            sameContract ? previous?.lastCompletedCursor : null,
          ),
          lastFullSuccessAt: Value(
            outcome.status == SyncComponentStatus.succeeded
                ? now
                : sameContract
                ? previous?.lastFullSuccessAt
                : null,
          ),
          currentState: Value(currentState),
          diagnosticMetadataJson: Value(jsonEncode(metadata)),
        ),
      );
    });
  }
}
