import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../utils/safe_diagnostics.dart';
import '../workspace/workspace_context.dart';
import 'sync_write_scope.dart';
import 'sync_models.dart';

typedef StagedComponentMerger =
    Future<void> Function(
      SyncComponent component,
      List<Map<String, dynamic>> changes,
    );

// Keep replay below the server's 90-day tombstone retention horizon.
const clientTombstoneReplayWindowDays = 88;

String? _validServerSequence(String? value) {
  if (value == null || !RegExp(r'^(0|[1-9]\d{0,18})$').hasMatch(value)) {
    return null;
  }
  final parsed = BigInt.tryParse(value);
  return parsed != null && parsed <= BigInt.parse('9223372036854775807')
      ? value
      : null;
}

String initialComponentAfterSequence({
  required int contractVersion,
  required int? completedContractVersion,
  required String? completedSequence,
  required DateTime? lastCompletedAt,
  required DateTime now,
}) {
  final lastCompletedUtc = lastCompletedAt?.toUtc();
  final stale =
      lastCompletedUtc != null &&
      now.toUtc().difference(lastCompletedUtc).inDays >
          clientTombstoneReplayWindowDays;
  if (stale || completedContractVersion != contractVersion) return '0';
  return _validServerSequence(completedSequence) ?? '0';
}

/// Reads a complete, sequence-bounded component traversal into durable
/// staging before publishing any rows or advancing its checkpoint.
class ComponentSyncPullAdapter {
  ComponentSyncPullAdapter({
    required this.db,
    required this.dio,
    this.writeScope,
  });

  final AppDatabase db;
  final Dio dio;
  final SyncWriteScope? writeScope;
  Future<T> _write<T>(Future<T> Function() action) =>
      writeScope?.write(action) ?? db.transaction(action);
  static const _ids = Uuid();
  static const _pageSize = 100;

  Future<String> pull({
    required String userId,
    required SyncComponent component,
    required int contractVersion,
    required StagedComponentMerger merge,
    String? projectionRevision,
  }) async {
    writeScope?.requireOwner(userId);
    await writeScope?.check();
    final componentName = component.name;
    final runId = _ids.v4();
    var staged = false;
    var phase = SyncFailurePhase.checkpointRead;
    try {
      final previous = await db.syncStateDao.getState(userId, componentName);
      var afterSequence = initialComponentAfterSequence(
        contractVersion: contractVersion,
        completedContractVersion: previous?.contractVersion,
        completedSequence: previous?.lastCompletedCursor,
        lastCompletedAt: previous?.lastFullSuccessAt,
        now: DateTime.now(),
      );
      final priorMetadata = previous?.diagnosticMetadataJson == null
          ? <String, dynamic>{}
          : jsonDecode(previous!.diagnosticMetadataJson!)
                as Map<String, dynamic>;
      if (projectionRevision != null &&
          priorMetadata['projectionRevision'] != projectionRevision) {
        // New local projection columns need a bounded replay. The previous
        // cursor is retained until the complete replay commits atomically.
        afterSequence = '0';
      }
      phase = SyncFailurePhase.stagingDiscard;
      await _write(
        () => db.syncStateDao.discardIncompleteRuns(userId, componentName),
      );

      var ordinal = 0;
      var includeCheckpoint = afterSequence != '0';
      var checkpointFallbackAttempted = false;
      String? cursor;
      String? previousCursor;
      String? firstPageAfter;
      String? throughSequence;

      while (true) {
        final query = <String, dynamic>{
          'contractVersion': contractVersion,
          'pageSize': _pageSize,
          'cursor': ?cursor,
          if (cursor == null && includeCheckpoint)
            'afterSequence': afterSequence,
        };
        Response<Map<String, dynamic>> response;
        phase = SyncFailurePhase.pageRequest;
        try {
          response = await dio.get<Map<String, dynamic>>(
            '/sync/${_routeName(component)}',
            queryParameters: query,
          );
        } on DioException catch (error) {
          // Older component-sync v2 servers rejected the additive checkpoint
          // query. A full replay remains safe and preserves compatibility.
          if (cursor == null &&
              includeCheckpoint &&
              !checkpointFallbackAttempted &&
              error.response?.statusCode == 400) {
            checkpointFallbackAttempted = true;
            includeCheckpoint = false;
            afterSequence = '0';
            continue;
          }
          rethrow;
        }
        phase = SyncFailurePhase.pageValidate;
        final body = response.data;
        if (body == null ||
            body['component'] != componentName ||
            body['contractVersion'] != contractVersion ||
            body['afterSequence'] is! String ||
            body['throughSequence'] is! String ||
            body['items'] is! List ||
            body['hasMore'] is! bool) {
          throw const FormatException('Component sync page is invalid.');
        }

        final pageAfter = body['afterSequence'] as String;
        final pageThrough = body['throughSequence'] as String;
        if (_validServerSequence(pageAfter) == null ||
            _validServerSequence(pageThrough) == null ||
            BigInt.parse(pageAfter) > BigInt.parse(pageThrough)) {
          throw const FormatException('Component sync sequence is invalid.');
        }
        if (cursor == null) {
          if (pageAfter != afterSequence) {
            throw const FormatException('Component sync checkpoint changed.');
          }
          firstPageAfter = pageAfter;
          throughSequence = pageThrough;
          phase = SyncFailurePhase.stagingBegin;
          await _write(
            () => db.syncStateDao.beginRun(
              SyncStagingRunsCompanion.insert(
                id: runId,
                userId: userId,
                component: componentName,
                contractVersion: contractVersion,
                afterSequence: pageAfter,
                throughSequence: pageThrough,
                startedAt: DateTime.now().toUtc(),
              ),
            ),
          );
          staged = true;
        } else if (pageThrough != throughSequence ||
            pageAfter == previousCursor ||
            BigInt.parse(pageAfter) <= BigInt.parse(previousCursor!)) {
          throw const FormatException('Component sync cursor did not advance.');
        }

        phase = SyncFailurePhase.pageValidate;
        final changes = body['items'] as List<dynamic>;
        final hasMore = body['hasMore'] as bool;
        final nextCursor = body['nextCursor'];
        if ((hasMore && (nextCursor is! String || nextCursor.isEmpty)) ||
            (!hasMore && nextCursor != null) ||
            (hasMore && changes.isEmpty) ||
            (nextCursor is String && nextCursor == cursor)) {
          throw const FormatException(
            'Component sync page boundary is invalid.',
          );
        }
        final stagedItems = <SyncStagingItemsCompanion>[];
        for (final rawEntry in changes) {
          if (rawEntry is! Map<String, dynamic>) {
            throw const FormatException('Component sync item is invalid.');
          }
          final hasServerSequence =
              rawEntry['serverSequence'] is String &&
              rawEntry['change'] is Map<String, dynamic>;
          final serverSequence = hasServerSequence
              ? rawEntry['serverSequence'] as String
              : ordinal.toString();
          final rawChange = hasServerSequence
              ? rawEntry['change'] as Map<String, dynamic>
              : rawEntry;
          final sequence = _validServerSequence(serverSequence);
          if (sequence == null ||
              rawChange['entityType'] is! String ||
              rawChange['entityId'] is! String ||
              rawChange['payload'] is! Map<String, dynamic>) {
            throw const FormatException('Component sync item is invalid.');
          }
          stagedItems.add(
            SyncStagingItemsCompanion.insert(
              runId: runId,
              serverSequence: int.parse(sequence),
              entityType: rawChange['entityType'] as String,
              entityId: rawChange['entityId'] as String,
              payloadJson: jsonEncode(rawChange),
            ),
          );
          ordinal++;
        }
        phase = SyncFailurePhase.stagingPage;
        await _write(
          () => db.syncStateDao.stagePage(
            runId: runId,
            items: stagedItems,
            nextCursor: hasMore ? nextCursor as String : pageThrough,
            isFinalPage: !hasMore,
          ),
        );
        if (!hasMore) break;
        previousCursor = pageAfter;
        cursor = nextCursor as String;
      }

      phase = SyncFailurePhase.pageValidate;
      final completedSequence = throughSequence;
      if (!staged || firstPageAfter == null || completedSequence == null) {
        throw const FormatException('Component sync traversal is incomplete.');
      }
      phase = SyncFailurePhase.stagedRead;
      await _write(
        () => db.syncStateDao.commitRunAfterMerge(
          runId: runId,
          merge: (items) async {
            phase = SyncFailurePhase.stagedDecode;
            final changes = items
                .map((item) {
                  final decoded = jsonDecode(item.payloadJson);
                  if (decoded is! Map<String, dynamic>) {
                    throw const FormatException(
                      'Staged component item is invalid.',
                    );
                  }
                  return decoded;
                })
                .toList(growable: false);
            phase = SyncFailurePhase.mergeApply;
            await merge(component, changes);
            phase = SyncFailurePhase.checkpointPublish;
          },
          completedAt: DateTime.now().toUtc(),
          diagnosticMetadataJson: projectionRevision == null
              ? null
              : jsonEncode({
                  ...priorMetadata,
                  'projectionRevision': projectionRevision,
                }),
        ),
      );
      return completedSequence;
    } on WorkspaceAccessFailure {
      rethrow;
    } on Object catch (error, stack) {
      // Record the original failure before a secondary cleanup can fail.
      if (error is! DioException) {
        SafeDiagnostics.logSyncFailure(
          component: componentName,
          phase: phase,
          error: error,
        );
      }
      if (staged) {
        try {
          await _write(() => db.syncStateDao.discardRun(runId));
        } on Object catch (cleanupError) {
          SafeDiagnostics.logSyncFailure(
            component: componentName,
            phase: SyncFailurePhase.stagingDiscard,
            error: cleanupError,
          );
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  String _routeName(SyncComponent component) => switch (component) {
    SyncComponent.account => 'account',
    SyncComponent.stable => 'stable',
    SyncComponent.medicationBridge => 'medication-bridge',
    SyncComponent.medication => 'medication',
  };
}
