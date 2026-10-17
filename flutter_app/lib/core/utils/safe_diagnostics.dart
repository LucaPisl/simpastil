import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:sqlite3/sqlite3.dart';

import '../api/scoped_access_error.dart';
import 'app_logger.dart';

/// Fixed operation names only; never derive a phase from exception text.
enum SyncFailurePhase {
  stageRun('stage_run'),
  checkpointRead('checkpoint_read'),
  stagingDiscard('staging_discard'),
  pageRequest('page_request'),
  pageValidate('page_validate'),
  stagingBegin('staging_begin'),
  stagingPage('staging_page'),
  stagedRead('staged_read'),
  stagedDecode('staged_decode'),
  mergeApply('merge_apply'),
  checkpointPublish('checkpoint_publish');

  const SyncFailurePhase(this.wireName);
  final String wireName;
}

/// Emits and persists a deliberately small allowlist of sync diagnostics.
/// Request data, headers, full URLs, and server messages never enter it.
abstract class SafeDiagnostics {
  static const _uuidPattern =
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';

  /// Inspect types and numeric SQLite codes, never messages, SQL or stacks.
  static Map<String, Object?> syncFailureEvent({
    required String component,
    required SyncFailurePhase phase,
    required Object error,
  }) => _syncFailureEvent(
    component: component,
    phase: phase,
    // A background database isolate wraps SQLite errors; report the cause.
    error: error is DriftRemoteException ? error.remoteCause : error,
  );

  static Map<String, Object?> _syncFailureEvent({
    required String component,
    required SyncFailurePhase phase,
    required Object error,
  }) => {
    'event': 'sync_stage_failed',
    'component': _safeComponent(component),
    'phase': phase.wireName,
    'category': switch (error) {
      SqliteException() => 'sqlite',
      FormatException() => 'format',
      TypeError() => 'type',
      StateError() => 'state',
      _ => 'other',
    },
    if (error is SqliteException) ...{
      'sqliteCode': error.resultCode,
      'sqliteExtendedCode': error.extendedResultCode,
    },
  };

  static void logSyncFailure({
    required String component,
    required SyncFailurePhase phase,
    required Object error,
  }) => AppLogger.debug(
    'SyncDiag',
    jsonEncode(
      syncFailureEvent(component: component, phase: phase, error: error),
    ),
  );

  static Map<String, Object?> accessRefusalEvent({
    String? component,
    String? entityType,
    String? payloadKind,
    String? phase,
    String? parentIdentity,
    String? legacyOwnerEvidence,
    required String reason,
  }) => {
    'event': 'sync_access_refused',
    'component': _safeComponent(component),
    'entityType':
        const {
          'profile',
          'pill',
          'schedule',
          'occurrence',
          'doseLog',
        }.contains(entityType)
        ? entityType
        : 'unknown',
    'payloadKind':
        const {
          'account',
          'migrationIssue',
          'profile',
          'pill',
          'schedule',
          'bridgeDose',
          'bridgeStock',
          'medicationOccurrence',
          'occurrenceEvent',
          'inventoryEvent',
          'identityMapping',
          'legacyEstimatedHistory',
          'tombstone',
        }.contains(payloadKind)
        ? payloadKind
        : 'unknown',
    'reason':
        const {
          'unavailable',
          'staleGrant',
          'wrongPerson',
          'unresolvedOrigin',
          'endpointMismatch',
          'ownerCollision',
          'staleNetworkTransition',
          'missing_entity',
          'owner_mismatch',
          'unsupported_entity_type',
        }.contains(reason)
        ? reason
        : 'unknown',
    if (phase != null)
      'phase':
          const {
            'bridge_existing_dose',
            'bridge_parent_import',
            'bridge_incoming_without_parent',
            'bridge_incoming_with_parent',
          }.contains(phase)
          ? phase
          : 'unknown',
    if (parentIdentity != null)
      'parentIdentity':
          const {
            'absent',
            'same_local_id',
            'different_local_id',
          }.contains(parentIdentity)
          ? parentIdentity
          : 'unknown',
    if (legacyOwnerEvidence != null)
      'legacyOwnerEvidence':
          const {
            'none',
            'current_owner',
            'other_owner',
            'ambiguous',
          }.contains(legacyOwnerEvidence)
          ? legacyOwnerEvidence
          : 'unknown',
  };

  static void logAccessRefusal({
    String? component,
    String? entityType,
    String? payloadKind,
    String? phase,
    String? parentIdentity,
    String? legacyOwnerEvidence,
    required String reason,
  }) => AppLogger.debug(
    'SyncDiag',
    jsonEncode(
      accessRefusalEvent(
        component: component,
        entityType: entityType,
        payloadKind: payloadKind,
        phase: phase,
        parentIdentity: parentIdentity,
        legacyOwnerEvidence: legacyOwnerEvidence,
        reason: reason,
      ),
    ),
  );

  static const _connectionAccessRefusalReasons = {
    'endpoint_not_allowed',
    'installation_scope_missing',
    'installation_endpoint_mismatch',
    'installation_scope_stale',
    'network_scope_stale',
    'connection_session_missing',
    'credential_bundle_missing',
    'credential_refresh_unavailable',
    'credential_refresh_stale',
    'credential_refresh_busy',
    'credential_refresh_rejected',
    'credential_refresh_uncertain',
    'credential_refresh_installation_required',
    'scope_changed_during_request',
    'access_check_failed',
  };

  static Map<String, Object?> connectionAccessRefusalEvent({
    required String path,
    required String reason,
  }) => {
    'event': 'connection_access_refused',
    'route': routeTemplate(path),
    'reason': _connectionAccessRefusalReasons.contains(reason)
        ? reason
        : 'access_check_failed',
  };

  static void logConnectionAccessRefusal({
    required String path,
    required String reason,
  }) => AppLogger.debug(
    'SyncDiag',
    jsonEncode(connectionAccessRefusalEvent(path: path, reason: reason)),
  );

  static Map<String, Object?> httpEvent({
    required String event,
    required String path,
    required int? statusCode,
    required Duration duration,
    String? correlationId,
    int? retryCount,
    int? clientBuild,
    String? component,
  }) => {
    'event':
        const {'http_started', 'http_succeeded', 'http_failed'}.contains(event)
        ? event
        : 'http_other',
    'route': routeTemplate(path),
    'component': _safeComponent(component),
    'statusClass': statusClass(statusCode),
    'durationMs': duration.inMilliseconds.clamp(0, 60000),
    'retryCount': (retryCount ?? 0).clamp(0, 10),
    'clientBuild':
        clientBuild != null && clientBuild > 0 && clientBuild < 1000000
        ? clientBuild
        : null,
    'correlationId': safeCorrelationId(correlationId),
  };

  static Map<String, Object?> stageOutcome({
    required String stageId,
    required String component,
    required String status,
    String? safeCorrelationId,
    required int? httpStatusCode,
    required Duration duration,
  }) => {
    'stage': _safeIdentifier(stageId),
    'component': _safeComponent(component),
    'route': routeTemplate('/sync/$component'),
    'outcome':
        const {
          'succeeded',
          'partiallySynced',
          'failed',
          'blocked',
        }.contains(status)
        ? status
        : 'failed',
    'statusClass': statusClass(httpStatusCode),
    'retryCount': 0,
    'clientBuild': null,
    'correlationId': safeCorrelationIdValue(safeCorrelationId),
    'durationMs': duration.inMilliseconds.clamp(0, 60000),
  };

  static String routeTemplate(String path) {
    final parsed = Uri.tryParse(path);
    final route = parsed?.path ?? '';
    if (route == '/capabilities') return route;
    if (route == '/profiles') return route;
    if (RegExp(r'^/profiles/[^/]+$').hasMatch(route)) {
      return '/profiles/:id';
    }
    if (RegExp(r'^/profiles/[^/]+/pills$').hasMatch(route)) {
      return '/profiles/:id/pills';
    }
    if (RegExp(r'^/profiles/[^/]+/pills/[^/]+$').hasMatch(route)) {
      return '/profiles/:id/pills/:id';
    }
    if (RegExp(r'^/profiles/[^/]+/logs(?:/[^/]+)?$').hasMatch(route)) {
      return '/profiles/:id/logs';
    }
    if (RegExp(r'^/pills/[^/]+/schedules(?:/[^/]+)?$').hasMatch(route)) {
      return '/pills/:id/schedules';
    }
    if (RegExp(r'^/logs(?:/[^/]+)?$').hasMatch(route)) return '/logs/:id';
    if (route == '/medication/commands' ||
        route == '/medication/inventory/commands' ||
        route == '/medication/bridge/commands' ||
        route == '/medication/legacy-split/reconcile') {
      return route;
    }
    if (route.startsWith('/sync/')) return '/sync/:component';
    return '/other';
  }

  static String statusClass(int? statusCode) {
    if (statusCode == null) return 'no_response';
    final group = statusCode ~/ 100;
    return group >= 1 && group <= 5 ? '${group}xx' : 'other';
  }

  static String? safeCorrelationId(String? value) =>
      value != null &&
          RegExp(_uuidPattern, caseSensitive: false).hasMatch(value)
      ? value
      : null;

  static String? safeErrorCodeValue(String? value) =>
      value != null && RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(value)
      ? value
      : null;

  static String? safeCorrelationIdValue(String? value) =>
      safeCorrelationId(value);

  static String _safeComponent(String? value) =>
      const {
        'account',
        'stable',
        'medicationBridge',
        'medication',
      }.contains(value)
      ? value!
      : 'unknown';

  static void logHttpEvent(Map<String, Object?> event) {
    AppLogger.debug('SyncDiag', jsonEncode(event));
  }

  static String _safeIdentifier(String value) =>
      RegExp(r'^[a-z][a-zA-Z0-9_-]{0,47}$').hasMatch(value) ? value : 'unknown';

  static String? errorCodeFrom(DioException error) {
    if (error.type == DioExceptionType.cancel &&
        error.message == scopedAccessUnavailableMessage) {
      return 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE';
    }
    final body = error.response?.data;
    final details = body is Map<String, dynamic> ? body['error'] : null;
    final code = details is Map<String, dynamic> ? details['code'] : null;
    return safeErrorCodeValue(code is String ? code : null);
  }

  static String? correlationIdFrom(DioException error) {
    final body = error.response?.data;
    final details = body is Map<String, dynamic> ? body['error'] : null;
    final id = details is Map<String, dynamic>
        ? details['correlationId']
        : null;
    return safeCorrelationId(id is String ? id : null);
  }
}
