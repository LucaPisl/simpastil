import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/app_localizations_en.dart';
import '../db/daos/medication_ledger_dao.dart';
import '../db/database.dart';
import '../medication/local_occurrence_snapshot.dart';
import '../medication/medication_repository.dart';
import '../medication/routine_repository.dart';
import '../medication/routine_definition.dart';
import '../notifications/notification_service.dart';
import '../notifications/reminder_copy.dart';
import '../notifications/reminder_preferences.dart';
import '../session/session_generation_repository.dart';
import '../storage/shared_preferences_provider.dart';
import '../utils/app_logger.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'projection_command_id.dart';
import 'projection_effects_gate.dart';
import 'projection_identity.dart';
import 'projection_registry.dart';
import '../medication/current_name_display.dart';
import '../notifications/reminder_channel.dart';
import 'reminder_eligibility.dart';
import 'reminder_id_ledger.dart';
import 'reminder_planning.dart';
import 'reminder_projection.dart';

const _legacyMigrationPreferenceKey = 'notification_occurrence_migration_v1';
const _statusPreferencePrefix = 'notification_projection_status_v1_';
const _androidSnoozeAdmissionLimit = 480;
const _auditBuildPreferenceKey = 'reminder_audit_build';
const _auditReportPreferenceKey = 'reminder_audit_report_v1';
const _legacyIdsPreferencePrefix = 'notif_ids_';
const _lowStockFiredPreferencePrefix = 'low_stock_fired_';
typedef ActiveNotificationActionsRefresher =
    Future<ActiveNotificationActionRefreshResult> Function({
      required List<Map<String, Object?>> envelopes,
    });

enum ProjectionReconciliationState { current, degraded, coverageShortened }

class ProjectionReconciliationReport {
  const ProjectionReconciliationReport({
    required this.userId,
    required this.sessionGeneration,
    required this.state,
    required this.desiredCount,
    required this.scheduledCount,
    required this.failedOperations,
    required this.availableCount,
    required this.invalidOccurrenceCount,
  });

  final String userId;
  final int sessionGeneration;
  final ProjectionReconciliationState state;
  final int desiredCount;
  final int scheduledCount;
  final int failedOperations;
  final int availableCount;
  final int invalidOccurrenceCount;

  bool get degraded => state == ProjectionReconciliationState.degraded;
  bool get coverageShortened =>
      state == ProjectionReconciliationState.coverageShortened;

  Map<String, Object?> toJson() => {
    'userId': userId,
    'sessionGeneration': sessionGeneration,
    'state': state.name,
    'desiredCount': desiredCount,
    'scheduledCount': scheduledCount,
    'failedOperations': failedOperations,
    'availableCount': availableCount,
    'invalidOccurrenceCount': invalidOccurrenceCount,
  };

  static ProjectionReconciliationReport? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final stateName = raw['state'];
    ProjectionReconciliationState? state;
    for (final value in ProjectionReconciliationState.values) {
      if (value.name == stateName) {
        state = value;
        break;
      }
    }
    if (state == null ||
        raw['userId'] is! String ||
        raw['sessionGeneration'] is! int ||
        raw['desiredCount'] is! int ||
        raw['scheduledCount'] is! int ||
        raw['failedOperations'] is! int ||
        raw['availableCount'] is! int ||
        raw['invalidOccurrenceCount'] is! int) {
      return null;
    }
    return ProjectionReconciliationReport(
      userId: raw['userId'] as String,
      sessionGeneration: raw['sessionGeneration'] as int,
      state: state,
      desiredCount: raw['desiredCount'] as int,
      scheduledCount: raw['scheduledCount'] as int,
      failedOperations: raw['failedOperations'] as int,
      availableCount: raw['availableCount'] as int,
      invalidOccurrenceCount: raw['invalidOccurrenceCount'] as int,
    );
  }
}

/// What the last audit sweep saw and did. Counts only: no names, copy or
/// payloads, so it is safe to persist and show in diagnostics.
class ReminderAuditReport {
  const ReminderAuditReport({
    required this.at,
    required this.ran,
    this.deferredReason,
    this.strict = false,
    this.pendingBefore = 0,
    this.desiredCount = 0,
    this.cancelledPending = 0,
    this.cancelledGhosts = 0,
    this.cancelledActiveDuplicates = 0,
    this.failed = 0,
    this.reasons = const {},
    this.skippedWorkspaces = 0,
    this.heldOutWorkspaces = 0,
    this.invalidOccurrences = 0,
  });

  const ReminderAuditReport.deferred(
    String reason, {
    required DateTime at,
    bool strict = false,
    int pendingBefore = 0,
  }) : this(
         at: at,
         ran: false,
         deferredReason: reason,
         strict: strict,
         pendingBefore: pendingBefore,
       );

  final DateTime at;
  final bool ran;
  final String? deferredReason;
  final bool strict;
  final int pendingBefore;
  final int desiredCount;
  final int cancelledPending;
  final int cancelledGhosts;
  final int cancelledActiveDuplicates;
  final int failed;
  final Map<String, int> reasons;

  /// Workspaces signed out here; their alarms were left alone.
  final int skippedWorkspaces;

  /// Workspaces that failed to reconcile this pass; their alarms were left
  /// alone and the pass will be retried.
  final int heldOutWorkspaces;

  /// Occurrences that could not be projected into a reminder.
  final int invalidOccurrences;

  static ReminderAuditReport? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final at = raw['at'] is String ? DateTime.tryParse(raw['at']) : null;
    if (at == null || raw['ran'] is! bool) return null;
    int count(String key) => raw[key] is int ? raw[key] as int : 0;
    final reasons = raw['reasons'];
    return ReminderAuditReport(
      at: at,
      ran: raw['ran'] as bool,
      deferredReason: raw['deferredReason'] is String
          ? raw['deferredReason'] as String
          : null,
      strict: raw['strict'] == true,
      pendingBefore: count('pendingBefore'),
      desiredCount: count('desiredCount'),
      cancelledPending: count('cancelledPending'),
      cancelledGhosts: count('cancelledGhosts'),
      cancelledActiveDuplicates: count('cancelledActiveDuplicates'),
      failed: count('failed'),
      reasons: {
        if (reasons is Map)
          for (final entry in reasons.entries)
            if (entry.key is String && entry.value is int)
              entry.key as String: entry.value as int,
      },
      skippedWorkspaces: count('skippedWorkspaces'),
      heldOutWorkspaces: count('heldOutWorkspaces'),
      invalidOccurrences: count('invalidOccurrences'),
    );
  }

  int get cancelledTotal =>
      cancelledPending + cancelledGhosts + cancelledActiveDuplicates;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'ran': ran,
    'deferredReason': deferredReason,
    'strict': strict,
    'pendingBefore': pendingBefore,
    'desiredCount': desiredCount,
    'cancelledPending': cancelledPending,
    'cancelledGhosts': cancelledGhosts,
    'cancelledActiveDuplicates': cancelledActiveDuplicates,
    'failed': failed,
    'reasons': reasons,
    'skippedWorkspaces': skippedWorkspaces,
    'heldOutWorkspaces': heldOutWorkspaces,
    'invalidOccurrences': invalidOccurrences,
  };
}

/// Preference key of the last audit report (counts only).
const reminderAuditReportPreferenceKey = _auditReportPreferenceKey;

/// The outcome of a pass over every workspace.
class ReconcileAllResult {
  const ReconcileAllResult({
    required this.ready,
    this.busy = false,
    this.audit,
    this.invalidOccurrences = 0,
    this.skippedWorkspaces = 0,
  });

  const ReconcileAllResult.failed() : this(ready: false);

  /// Every workspace this phone can still reach reconciled, with no failed
  /// operation. An occurrence too broken to project, or a workspace signed
  /// out here, is counted separately and never makes the pass unready: a retry
  /// would hit the same wall.
  final bool ready;

  /// Occurrences that could not be turned into a reminder, across workspaces.
  final int invalidOccurrences;

  /// Workspaces with no usable access on this phone; their alarms are left
  /// alone.
  final int skippedWorkspaces;

  /// Another process held the projection effects gate for too long.
  final bool busy;
  final ReminderAuditReport? audit;

  /// A result worth no retry: ready, or nothing a retry could change.
  bool get healthy => ready && !busy;
}

enum ReminderResetFailure {
  permission,
  unavailable,
  prepare,
  clear,
  rebuild,

  /// The reminder registry is unreadable, so pending snoozes cannot be told
  /// from reminders. Nothing was cancelled.
  registry,
}

class ReminderResetResult {
  const ReminderResetResult.success({
    required this.removed,
    required this.scheduled,
  }) : failure = null,
       restoring = false;
  const ReminderResetResult.failed(this.failure, {this.restoring = false})
    : removed = 0,
      scheduled = 0;

  final ReminderResetFailure? failure;

  /// The rebuild did not finish at once but is still being retried in the
  /// background; the reminders come back without another tap.
  final bool restoring;
  final int removed;
  final int scheduled;
  bool get succeeded => failure == null;
}

/// Collects, across one all-workspace pass, every id that is legitimately
/// pending or delivered so the audit can tell everything else apart.
class _AuditCollector {
  final desired = <int, Set<String>>{};
  final preserved = <int>{};

  /// Workspaces this pass could not reconcile (signed out, or degraded). Their
  /// alarms are not ours to judge from a partial picture.
  final heldOutOwners = <String>{};

  /// The subset of [heldOutOwners] that failed to reconcile (as opposed to
  /// being signed out here). While any exists the picture is incomplete.
  final failedOwners = <String>{};
}

class ProjectionReconciler {
  ProjectionReconciler({
    required AppDatabase database,
    required SharedPreferences preferences,
    required SessionGenerationRepository generations,
    required ReminderNotificationPlatform platform,
    required ReminderPlatformKind platformKind,
    DateTime Function()? clock,
    WorkspaceAccessRepository? access,
    ProjectionEffectsGate? effectsGate,
    ActiveNotificationActionsRefresher? refreshActiveActions,
  }) : _database = database,
       _preferences = preferences,
       _generations = generations,
       _platform = platform,
       _platformKind = platformKind,
       _clock = clock ?? DateTime.now,
       _access = access ?? generations.access,
       _effectsGate =
           effectsGate ??
           access?.effectsGate ??
           generations.access?.effectsGate,
       _refreshActiveActions = refreshActiveActions;

  final AppDatabase _database;
  final SharedPreferences _preferences;
  final SessionGenerationRepository _generations;
  final ReminderNotificationPlatform _platform;
  final ReminderPlatformKind _platformKind;
  final DateTime Function() _clock;
  final WorkspaceAccessRepository? _access;
  final ProjectionEffectsGate? _effectsGate;
  final ActiveNotificationActionsRefresher? _refreshActiveActions;

  bool _ledgerWriteFailed = false;

  static String statusKeyForUser(String userId) =>
      '$_statusPreferencePrefix$userId';

  static ReminderPlatformKind get currentPlatformKind {
    if (Platform.isAndroid) return ReminderPlatformKind.android;
    if (Platform.isIOS) return ReminderPlatformKind.ios;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => ReminderPlatformKind.android,
      TargetPlatform.iOS => ReminderPlatformKind.ios,
      _ => ReminderPlatformKind.other,
    };
  }

  static ProjectionReconciliationReport? readStatus(
    SharedPreferences preferences,
    String userId,
  ) {
    final raw = preferences.getString(statusKeyForUser(userId));
    if (raw == null) return null;
    try {
      return ProjectionReconciliationReport.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<ProjectionReconciliationReport?> reconcile({
    SessionIdentity? identity,
    Locale? locale,
    ProjectionIdentity? projectionIdentity,
  }) => _reconcile(
    identity: identity,
    locale: locale,
    projectionIdentity: projectionIdentity,
  );

  Future<ProjectionReconciliationReport?> _reconcile({
    SessionIdentity? identity,
    Locale? locale,
    ProjectionIdentity? projectionIdentity,
    List<_ActiveNotificationActionCandidate> activeActionsToRetain = const [],
    _AuditCollector? collector,
  }) async {
    final protected = _access;
    if (protected != null) {
      if (identity != null && projectionIdentity == null) return null;
      final context = projectionIdentity != null
          ? await projectionIdentity.resolve(protected)
          : identity == null
          ? await protected.currentContext()
          : await protected.contextForOwner(identity.$1);
      if (context == null) return null;
      projectionIdentity = ProjectionIdentity.fromContext(context);
      identity = (context.ownerUserId, context.accessEpoch);
    }
    final resolvedIdentity = identity ?? await _generations.currentIdentity();
    if (resolvedIdentity == null) return null;
    final request = _ReconcileRequest(
      identity: resolvedIdentity,
      locale: locale,
      projectionIdentity: projectionIdentity,
      activeActionsToRetain: activeActionsToRetain,
      collector: collector,
    );
    final prepared = await _prepare(request);
    if (prepared == null) return null;
    return serializeNotificationWork(
      () => _effects(() async {
        await _preferences.reload();
        return _reconcileOne(request, prepared);
      }),
    );
  }

  /// Reconciles every workspace, then (only when all of them came out ready)
  /// retires orphan legacy alarms, audits what is still pending and removes
  /// retired channels. A failure of one step never aborts the others: the
  /// result says what was not ready so a caller can retry.
  ///
  /// [buildKey] identifies the installed build; the first pass seen under a new
  /// key runs a strict audit and records the key only after that audit ran.
  Future<ReconcileAllResult> reconcileAll({
    Locale? locale,
    bool refreshActiveActions = false,
    String? buildKey,
  }) async {
    final access = _access;
    if (access == null) {
      final report = await reconcile(locale: locale);
      return ReconcileAllResult(ready: report != null && !report.degraded);
    }
    final startedAt = _clock().toUtc();
    var busy = false;
    Future<T?> guarded<T>(String step, Future<T> Function() action) async {
      try {
        return await action();
      } on ProjectionEffectsBusy {
        busy = true;
      } on Object catch (error) {
        AppLogger.warning(
          'ProjectionReconciler',
          'Reminder pass step $step failed: ${error.runtimeType}',
        );
      }
      return null;
    }

    var allReady = true;
    if (await guarded('retireUnavailable', retireUnavailable) == null) {
      allReady = false;
    }
    final workspaces = await guarded('listWorkspaces', () async {
      await access.workspaces.ensureLocal();
      return _database.select(_database.careWorkspaces).get();
    });
    if (workspaces == null) {
      return ReconcileAllResult(ready: false, busy: busy);
    }
    if (_platformKind == ReminderPlatformKind.android) {
      // Shrink an incumbent's older allocation before publishing a newly
      // eligible workspace's share. Ordering conveys no authority to mutate it.
      final pendingCounts = <String, int>{};
      final pendingNow = await guarded(
        'pending',
        () => _platform.pendingRequests(),
      );
      for (final pending in pendingNow ?? const <PlatformReminderRequest>[]) {
        final payload = _payload(pending.payload);
        if (_isReminderPayload(pending.payload) &&
            payload is Map &&
            payload['userId'] is String) {
          final owner = payload['userId'] as String;
          pendingCounts[owner] = (pendingCounts[owner] ?? 0) + 1;
        }
      }
      workspaces.sort(
        (a, b) => (pendingCounts[b.ownerUserId] ?? 0).compareTo(
          pendingCounts[a.ownerUserId] ?? 0,
        ),
      );
    }
    final collector = _AuditCollector();
    _ledgerWriteFailed = false;
    // The audit trusts the per-workspace passes only if care data did not
    // change after the first of them began.
    (int, int)? baselineRevision;
    try {
      baselineRevision = await _careRevision();
    } on Object {
      baselineRevision = null;
    }
    final readyContexts = <WorkspaceContext>[];
    var skipped = 0;
    var invalid = 0;
    for (final workspace in workspaces) {
      final owner = workspace.ownerUserId;
      WorkspaceContext? context;
      var contextFailed = false;
      try {
        context = await access.contextForOwner(owner);
      } on ProjectionEffectsBusy {
        busy = true;
        contextFailed = true;
      } on Object catch (error) {
        contextFailed = true;
        AppLogger.warning(
          'ProjectionReconciler',
          'Reminder pass step context failed: ${error.runtimeType}',
        );
      }
      if (context == null) {
        // Signed out or no longer accessible: nothing to reconcile, and its
        // alarms are neither audited nor counted against readiness. A lookup
        // that threw is different: it may be transient, so retry.
        collector.heldOutOwners.add(owner);
        if (contextFailed) {
          collector.failedOwners.add(owner);
          allReady = false;
        } else {
          skipped++;
        }
        continue;
      }
      final report = await guarded('reconcile', () async {
        final actionsToRetain = refreshActiveActions
            ? await _upgradeActiveActionsForContext(context!)
            : const <_ActiveNotificationActionCandidate>[];
        return _reconcile(
          projectionIdentity: ProjectionIdentity.fromContext(context!),
          locale: locale,
          activeActionsToRetain: actionsToRetain,
          collector: collector,
        );
      });
      // Degraded only by occurrences that cannot be projected: the workspace's
      // other reminders are in place, so it still counts as reconciled.
      final invalidOnly =
          report != null &&
          report.degraded &&
          report.failedOperations == 0 &&
          report.invalidOccurrenceCount > 0;
      if (report == null || (report.degraded && !invalidOnly)) {
        allReady = false;
        collector.heldOutOwners.add(owner);
        collector.failedOwners.add(owner);
      } else {
        readyContexts.add(context);
        invalid += report.invalidOccurrenceCount;
      }
    }

    ReminderAuditReport? audit;
    if (readyContexts.isNotEmpty) {
      if (allReady) {
        await guarded(
          'orphanLegacy',
          () => serializeNotificationWork(
            () => _effects(() => _retireOrphanLegacyAlarms(readyContexts)),
          ),
        );
      }
      // The strict upgrade sweep is only trusted over a complete picture.
      final strict =
          allReady &&
          buildKey != null &&
          _preferences.getString(_auditBuildPreferenceKey) != buildKey;
      audit = await guarded(
        'audit',
        () => serializeNotificationWork(
          () => _effects(
            () => _auditReminders(
              readyContexts,
              collector,
              startedAt,
              strict,
              baselineRevision: baselineRevision,
              skippedWorkspaces: skipped,
              heldOutWorkspaces: collector.heldOutOwners.length - skipped,
              invalidOccurrences: invalid,
            ),
          ),
        ),
      );
      if (strict && audit != null && audit.ran && audit.failed == 0) {
        try {
          await _preferences.setString(_auditBuildPreferenceKey, buildKey);
        } on Object catch (error) {
          AppLogger.warning(
            'ProjectionReconciler',
            'Audit build marker not saved: ${error.runtimeType}',
          );
        }
      }
      // Retired channels go only after a complete, fully successful audit that
      // left no reminder pending or wanted on them, and only while every
      // grant still holds.
      final platform = _platform;
      if (platform is RetiredChannelNotificationPlatform &&
          allReady &&
          audit != null &&
          audit.ran &&
          audit.failed == 0) {
        await guarded(
          'deleteRetiredChannels',
          () => serializeNotificationWork(
            () => _effects(() async {
              if (!await _retiredChannelsClear(readyContexts, collector)) {
                return;
              }
              await (platform as RetiredChannelNotificationPlatform)
                  .deleteRetiredChannels();
            }),
          ),
        );
      }
    } else {
      audit = ReminderAuditReport.deferred('notReady', at: startedAt);
    }
    return ReconcileAllResult(
      ready: allReady && readyContexts.isNotEmpty,
      busy: busy,
      audit: audit,
      invalidOccurrences: invalid,
      skippedWorkspaces: skipped,
    );
  }

  /// Whether no reminder pending or wanted on a retired channel remains. A
  /// pending alarm's channel is the one its registry entry recorded; a
  /// delivered reminder reports its own.
  Future<bool> _retiredChannelsClear(
    List<WorkspaceContext> contexts,
    _AuditCollector collector,
  ) async {
    final access = _access;
    if (access == null) return false;
    await _preferences.reload();
    for (final context in contexts) {
      if (await ProjectionIdentity.fromContext(context).resolve(access) ==
          null) {
        return false;
      }
    }
    final Map<int, Map<String, Object?>> registry;
    try {
      registry = _readRegistry();
    } on FormatException {
      return false;
    }
    await _platform.initialize();
    final pendingIds = {
      for (final item in await _platform.pendingRequests()) item.id,
    };
    final platform = _platform;
    return retiredChannelsClear(
      registry: registry,
      pendingIds: pendingIds,
      active: platform is ActiveReminderNotificationPlatform
          ? await (platform as ActiveReminderNotificationPlatform)
                .activeReminders()
          : const [],
      wantedIds: {...collector.desired.keys, ...collector.preserved},
      retiredChannelIds: retiredReminderChannelIds().toSet(),
      currentRevision: kReminderChannelRevision,
    );
  }

  Future<void> _recordInLedger(Iterable<int> ids) async {
    try {
      await ReminderIdLedger(_preferences).record(ids, _clock());
    } on Object catch (error) {
      // The ledger is a safety net; scheduling proceeds without it, and the
      // audit then stands down because it cannot tell fresh alarms apart.
      _ledgerWriteFailed = true;
      AppLogger.warning(
        'ProjectionReconciler',
        'Reminder ledger not updated: ${error.runtimeType}',
      );
    }
  }

  /// Cancels pending reminders no workspace wants and nothing protects, then
  /// collapses duplicate delivered notifications. Runs inside the effects gate
  /// and rechecks every grant and the care revision before each cancel.
  Future<ReminderAuditReport> _auditReminders(
    List<WorkspaceContext> contexts,
    _AuditCollector collector,
    DateTime startedAt,
    bool strict, {
    (int, int)? baselineRevision,
    int skippedWorkspaces = 0,
    int heldOutWorkspaces = 0,
    int invalidOccurrences = 0,
  }) async {
    final access = _access;
    final now = _clock().toUtc();
    Future<ReminderAuditReport> finish(ReminderAuditReport report) async {
      try {
        await _preferences.setString(
          _auditReportPreferenceKey,
          jsonEncode(report.toJson()),
        );
      } on Object {
        // The report is diagnostic only.
      }
      return report;
    }

    if (access == null) {
      return ReminderAuditReport.deferred('noAccess', at: now, strict: strict);
    }
    await _preferences.reload();
    final revision = await _careRevision();
    if (_ledgerWriteFailed) {
      return finish(
        ReminderAuditReport.deferred(
          'ledgerUnwritable',
          at: now,
          strict: strict,
        ),
      );
    }
    if (baselineRevision != null && baselineRevision != revision) {
      return finish(
        ReminderAuditReport.deferred('changed', at: now, strict: strict),
      );
    }
    Future<bool> stillSafe() async {
      for (final context in contexts) {
        if (await ProjectionIdentity.fromContext(context).resolve(access) ==
            null) {
          return false;
        }
      }
      return await _careRevision() == revision;
    }

    final Map<int, Map<String, Object?>> registry;
    try {
      registry = _readRegistry();
    } on FormatException {
      return finish(
        ReminderAuditReport.deferred(
          'registryUnreadable',
          at: now,
          strict: strict,
        ),
      );
    }
    await _platform.initialize();
    final pending = {
      for (final item in await _platform.pendingRequests()) item.id: item,
    };
    final platform = _platform;
    final activeNow = platform is ActiveReminderNotificationPlatform
        ? await (platform as ActiveReminderNotificationPlatform)
              .activeReminders()
        : const <PlatformActiveReminder>[];
    final ledgerStore = ReminderIdLedger(_preferences);
    final ledger = ledgerStore.read();
    final plan = planReminderAudit(
      allWorkspacesReady: true,
      pendingById: pending,
      desiredProjectionIds: collector.desired,
      // Ids still listed by an unfinished legacy retirement belong to that
      // retirement until it completes; only the strict upgrade sweep, which
      // clears those lists itself, may take them.
      preservedIds: {
        ...(strict
            ? collector.preserved
            : {...collector.preserved, ..._legacyListedIds()}),
        // A workspace this pass could not judge keeps whatever it has armed.
        ..._heldOutPendingIds(
          pending,
          registry,
          collector.heldOutOwners,
          protectUnowned: collector.failedOwners.isNotEmpty,
        ),
      },
      activeIds: {for (final item in activeNow) item.id},
      registry: registry,
      ledger: ledger,
      now: now,
      passStartedAt: startedAt,
    );
    if (plan.deferred) {
      return finish(
        ReminderAuditReport.deferred(
          plan.deferredReason!,
          at: now,
          strict: strict,
          pendingBefore: plan.pendingBefore,
        ),
      );
    }

    var failed = 0;
    var cancelledPending = 0;
    var cancelledGhosts = 0;
    var duplicates = 0;
    String? deferredReason;
    final reasons = <String, int>{};
    final cancelledIds = <int>[];
    for (final entry in plan.cancel.entries) {
      if (!await stillSafe()) {
        deferredReason = 'changed';
        break;
      }
      try {
        await _platform.cancel(entry.key);
        cancelledIds.add(entry.key);
        reasons[entry.value.name] = (reasons[entry.value.name] ?? 0) + 1;
        if (entry.value == ReminderAuditReason.ledgerGhost) {
          cancelledGhosts++;
        } else {
          cancelledPending++;
        }
        if (ProjectionRegistry.isReminder(registry[entry.key])) {
          registry.remove(entry.key);
          await _persistRegistry(registry);
        }
      } on Object catch (error) {
        failed++;
        AppLogger.warning(
          'ProjectionReconciler',
          'Audit cancellation failed: ${error.runtimeType}',
        );
      }
    }
    if (cancelledIds.isNotEmpty) {
      try {
        await ledgerStore.remove(cancelledIds);
      } on Object {
        // A leftover ledger id is cancelled again, harmlessly, next time.
      }
    }

    if (deferredReason == null &&
        platform is ActiveReminderNotificationPlatform) {
      try {
        final keep = {...collector.desired.keys, ...collector.preserved};
        final dedupe = planActiveDedupe(
          active: await (platform as ActiveReminderNotificationPlatform)
              .activeReminders(),
          registry: registry,
          keepIds: keep,
          isAppChannel: (id) => id != null && isKnownReminderChannelId(id),
          ledger: ledgerStore.read(),
          now: now,
          passStartedAt: startedAt,
        );
        for (final id in dedupe) {
          if (!await stillSafe()) {
            deferredReason = 'changed';
            break;
          }
          try {
            await _platform.cancel(id);
            duplicates++;
            if (ProjectionRegistry.isReminder(registry[id])) {
              registry.remove(id);
              await _persistRegistry(registry);
            }
          } on Object {
            failed++;
          }
        }
      } on Object catch (error) {
        failed++;
        AppLogger.warning(
          'ProjectionReconciler',
          'Active duplicate review failed: ${error.runtimeType}',
        );
      }
    }

    if (strict && deferredReason == null) {
      failed += await _clearLegacyIdLists(collector, registry, stillSafe);
    }
    return finish(
      ReminderAuditReport(
        at: now,
        ran: deferredReason == null,
        deferredReason: deferredReason,
        strict: strict,
        pendingBefore: plan.pendingBefore,
        desiredCount: collector.desired.length,
        cancelledPending: cancelledPending,
        cancelledGhosts: cancelledGhosts,
        cancelledActiveDuplicates: duplicates,
        failed: failed,
        reasons: reasons,
        skippedWorkspaces: skippedWorkspaces,
        heldOutWorkspaces: heldOutWorkspaces,
        invalidOccurrences: invalidOccurrences,
      ),
    );
  }

  /// Pending ids whose payload or registry entry names a workspace owner this
  /// pass could not reconcile.
  Set<int> _heldOutPendingIds(
    Map<int, PlatformReminderRequest> pending,
    Map<int, Map<String, Object?>> registry,
    Set<String> heldOut, {
    required bool protectUnowned,
  }) {
    if (heldOut.isEmpty) return const {};
    final ids = <int>{};
    for (final entry in pending.entries) {
      final payload = _payload(entry.value.payload);
      final owner =
          (payload is Map ? payload['userId'] : null) ??
          registry[entry.key]?['userId'];
      // An alarm that names no owner (a pre-registry shape) cannot be judged
      // while a workspace is unreconciled; a complete pass retires it.
      if (owner is String ? heldOut.contains(owner) : protectUnowned) {
        ids.add(entry.key);
      }
    }
    return ids;
  }

  /// Every id still listed under a `notif_ids_*` key. Those keys are named by
  /// person (profile), not by workspace owner, so they cannot be matched to a
  /// live workspace; an unfinished legacy retirement owns all of them until the
  /// strict upgrade sweep clears the lists.
  Set<int> _legacyListedIds() {
    final ids = <int>{};
    for (final key in _preferences.getKeys()) {
      if (!key.startsWith(_legacyIdsPreferencePrefix)) continue;
      final raw = _preferences.getString(key);
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) ids.addAll(decoded.whereType<int>());
      } on FormatException {
        continue;
      }
    }
    return ids;
  }

  /// After an upgrade, retires ids still listed under `notif_ids_*` by builds
  /// that kept per-person lists, then drops a list once every id is cancelled.
  /// Returns how many ids could not be cancelled.
  Future<int> _clearLegacyIdLists(
    _AuditCollector collector,
    Map<int, Map<String, Object?>> registry,
    Future<bool> Function() stillSafe,
  ) async {
    var failed = 0;
    for (final key in _preferences.getKeys().toList()) {
      if (!key.startsWith(_legacyIdsPreferencePrefix)) continue;
      final raw = _preferences.getString(key);
      if (raw == null) continue;
      final List<int> ids;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List || decoded.any((id) => id is! int)) continue;
        ids = decoded.cast<int>();
      } on FormatException {
        continue;
      }
      var clean = true;
      for (final id in ids.toSet()) {
        if (collector.desired.containsKey(id) ||
            collector.preserved.contains(id) ||
            registry.containsKey(id)) {
          continue;
        }
        if (!await stillSafe()) {
          // Grants or care data moved on: leave this list for a later pass.
          return failed + 1;
        }
        try {
          await _platform.cancel(id);
        } on Object {
          clean = false;
          failed++;
        }
      }
      if (clean) await _preferences.remove(key);
    }
    return failed;
  }

  Future<List<_ActiveNotificationActionCandidate>>
  _upgradeActiveActionsForContext(WorkspaceContext context) async {
    final refresh = _refreshActiveActions;
    final access = _access;
    if (refresh == null ||
        access == null ||
        _platformKind != ReminderPlatformKind.android) {
      return const [];
    }
    final projectionIdentity = ProjectionIdentity.fromContext(context);
    final request = _ReconcileRequest(
      identity: (context.ownerUserId, context.accessEpoch),
      locale: null,
      projectionIdentity: projectionIdentity,
    );

    try {
      return await serializeNotificationWork(
        () => _effects(() async {
          await _preferences.reload();
          final snapshot = await _readCareSnapshot(request);
          if (snapshot == null || !snapshot.preferences.fullDetails) {
            return const <_ActiveNotificationActionCandidate>[];
          }
          final occurrences = {
            for (final occurrence in snapshot.occurrences)
              occurrence.id: occurrence,
          };
          final registry = _readRegistry();
          final repository = MedicationRepository(
            _database,
            access: access,
            context: context,
          );
          final candidates = <_ActiveNotificationActionCandidate>[];
          final usedIds = <int>{};

          for (final entry in registry.entries) {
            final stored = entry.value;
            if (!ProjectionRegistry.isReminder(stored) ||
                !_owns(stored, request.identity, projectionIdentity) ||
                stored['id'] != entry.key ||
                stored['allowCareActions'] != true ||
                stored['publicationPending'] == true ||
                stored['actionPresentationVersion'] ==
                    reminderActionPresentationVersion) {
              continue;
            }
            final occurrenceId = stored['occurrenceId'];
            final projectionId = stored['projectionId'];
            final stateVersion = stored['stateVersion'];
            final occurrence = occurrences[occurrenceId];
            if (occurrenceId is! String ||
                projectionId is! String ||
                stateVersion is! int ||
                occurrence == null ||
                occurrence.userId != context.ownerUserId ||
                occurrence.source != 'scheduled' ||
                !occurrence.expected ||
                occurrence.provenance != 'exact' ||
                occurrence.state != 'pending' ||
                occurrence.supersededAt != null ||
                occurrence.stateVersion != stateVersion ||
                occurrence.pillId == null ||
                occurrence.scheduleId == null) {
              continue;
            }

            final variants = <(String, int?)>[];
            if (stored['kind'] == 'snooze') {
              variants.add(('snooze', null));
            } else if (stored['kind'] == 'reminder') {
              variants.add(('reminder', null));
              for (final offset
                  in snapshot.preferences
                      .choiceFor(occurrence.scheduleId)
                      .followUpMinutes) {
                variants.add((followUpReminderKind(offset), offset));
              }
            } else {
              continue;
            }

            try {
              final schedule = decodeScheduleSnapshot(
                jsonDecode(occurrence.scheduleSnapshotJson)
                    as Map<String, dynamic>,
              );
              if (!snapshotOwns(
                    schedule,
                    context.ownerUserId,
                    context.workspaceId,
                  ) ||
                  !snapshot.activeProfileIds.contains(schedule.profileId) ||
                  schedule.frequency == 'prn' ||
                  schedule.timeZone != occurrence.timeZone) {
                continue;
              }
            } on Object {
              continue;
            }

            for (final (kind, followUpMinutes) in variants) {
              final expectedProjectionId = reminderProjectionId(
                userId: context.ownerUserId,
                sessionGeneration: context.accessEpoch,
                occurrenceId: occurrence.id,
                kind: kind,
                workspaceId: context.workspaceId,
                grantEpoch: context.accessEpoch,
                stateVersion: occurrence.stateVersion,
              );
              if (projectionId != expectedProjectionId ||
                  !notificationIdMatchesProjection(
                    expectedProjectionId,
                    entry.key,
                  ) ||
                  !usedIds.add(entry.key)) {
                continue;
              }
              if (!await repository.isCurrentReminderActionForReview(
                occurrenceId: occurrence.id,
                projectionId: expectedProjectionId,
                kind: kind,
                deliveredStateVersion: occurrence.stateVersion,
              )) {
                continue;
              }
              final payload = jsonEncode({
                ...projectionIdentity.toJson(),
                'occurrenceId': occurrence.id,
                'projectionId': expectedProjectionId,
                'userId': context.ownerUserId,
                'sessionGeneration': context.accessEpoch,
                'stateVersion': occurrence.stateVersion,
                if (followUpMinutes != null) 'followUpMinutes': followUpMinutes,
              });
              candidates.add(
                _ActiveNotificationActionCandidate(
                  notificationId: entry.key,
                  occurrenceId: occurrence.id,
                  projectionId: expectedProjectionId,
                  kind: kind,
                  stateVersion: occurrence.stateVersion,
                  payload: payload,
                  identity: projectionIdentity,
                ),
              );
              break;
            }
          }

          if (candidates.isEmpty ||
              !await _isCurrent(request.identity, projectionIdentity) ||
              (await _readCareSnapshot(request))?.fingerprint !=
                  snapshot.fingerprint) {
            return const <_ActiveNotificationActionCandidate>[];
          }

          late final ActiveNotificationActionRefreshResult result;
          try {
            result = await refresh(
              envelopes: [
                for (final candidate in candidates) candidate.envelope,
              ],
            );
          } on Object catch (error) {
            AppLogger.warning(
              'ProjectionReconciler',
              'Active notification action refresh deferred: ${error.runtimeType}',
            );
            // A transport failure cannot tell us whether an otherwise valid
            // dose is still visible. Retain these validated IDs conservatively;
            // the old presentation remains eligible for retry next startup.
            return candidates;
          }

          final refreshed = result.refreshedIds;
          var registryChanged = false;
          for (final candidate in candidates) {
            if (refreshed.contains(candidate.notificationId)) {
              registry[candidate.notificationId] = {
                ...registry[candidate.notificationId]!,
                'actionPresentationVersion': reminderActionPresentationVersion,
              };
              registryChanged = true;
            }
          }
          if (registryChanged) await _persistRegistry(registry);
          if (result.failedIds.isNotEmpty) {
            AppLogger.warning(
              'ProjectionReconciler',
              'Active notification action refresh failed for ${result.failedIds.length} dose(s)',
            );
          }
          if (!await _isCurrent(request.identity, projectionIdentity) ||
              (await _readCareSnapshot(request))?.fingerprint !=
                  snapshot.fingerprint) {
            return const <_ActiveNotificationActionCandidate>[];
          }
          return [
            for (final candidate in candidates)
              if (result.activeIds.contains(candidate.notificationId))
                candidate,
          ];
        }),
      );
    } on Object catch (error) {
      AppLogger.warning(
        'ProjectionReconciler',
        'Active notification review unavailable: ${error.runtimeType}',
      );
      return const [];
    }
  }

  Future<List<Profile>> _eligibleProfiles(String owner) async {
    if (_access == null) return _database.profilesDao.getActiveByUserId(owner);
    final rows = await _database
        .customSelect(
          'SELECT p.* FROM profiles p JOIN device_person_reminders r ON r.profile_id=p.id WHERE p.user_id=? AND p.is_deleted=0 AND r.enabled=1',
          variables: [Variable<String>(owner)],
          readsFrom: {_database.profiles, _database.devicePersonReminders},
        )
        .get();
    return rows.map((row) => _database.profiles.map(row.data)).toList();
  }

  Future<int> _androidWorkspaceBudget() async {
    final access = _access;
    if (access == null) return androidReminderBudget;
    final workspaces = await _database.select(_database.careWorkspaces).get();
    var eligible = 0;
    for (final workspace in workspaces) {
      if (await access.contextForOwner(workspace.ownerUserId) != null &&
          (await _eligibleProfiles(workspace.ownerUserId)).isNotEmpty) {
        eligible++;
      }
    }
    return androidWorkspaceShare(eligible);
  }

  Future<T> _effects<T>(Future<T> Function() action) =>
      _effectsGate?.run(action) ?? action();

  Future<bool> scheduleSnooze({
    required SessionIdentity identity,
    required String occurrenceId,
    required Duration delay,
    required AppLocalizations localizations,
    ProjectionIdentity? projectionIdentity,
    int? deliveredStateVersion,
    Future<void> Function()? requireEffectAdmission,
  }) async {
    final access = _access;
    if (access != null) {
      if (projectionIdentity == null ||
          deliveredStateVersion == null ||
          identity.$1 != projectionIdentity.ownerId ||
          identity.$2 != projectionIdentity.grantEpoch) {
        return false;
      }
      final context = await projectionIdentity.resolve(access);
      if (context == null) return false;
      projectionIdentity = ProjectionIdentity.fromContext(context);
      identity = (context.ownerUserId, context.accessEpoch);
    }
    if (delay <= Duration.zero ||
        !await _isCurrent(identity, projectionIdentity)) {
      return false;
    }
    // Permission reads and protected care snapshot computation precede the
    // effects gate. Permission prompts are owned by the foreground flow.
    if (!await _platform.hasExactAlarmPermission() ||
        !await _platform.hasNotificationPermission()) {
      return false;
    }
    final prepared = await _prepare(
      _ReconcileRequest(
        identity: identity,
        locale: null,
        projectionIdentity: projectionIdentity,
      ),
      materialize: false,
    );
    final occurrence = prepared?.occurrences
        .where((row) => row.id == occurrenceId)
        .firstOrNull;
    if (occurrence == null ||
        occurrence.source != 'scheduled' ||
        !occurrence.expected ||
        occurrence.provenance != 'exact' ||
        occurrence.state != 'pending' ||
        occurrence.supersededAt != null ||
        occurrence.pillId == null ||
        occurrence.scheduleId == null) {
      return false;
    }
    final snapshot = decodeScheduleSnapshot(
      jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>,
    );
    if ((projectionIdentity != null &&
            deliveredStateVersion != occurrence.stateVersion) ||
        snapshot.timeZone != occurrence.timeZone ||
        !prepared!.activeProfileIds.contains(snapshot.profileId)) {
      return false;
    }
    final projectionId = reminderProjectionId(
      userId: identity.$1,
      sessionGeneration: identity.$2,
      occurrenceId: occurrence.id,
      kind: 'snooze',
      workspaceId: projectionIdentity?.workspaceId,
      grantEpoch: projectionIdentity?.grantEpoch,
      stateVersion: projectionIdentity == null ? null : occurrence.stateVersion,
    );
    final id = notificationIdForProjection(projectionId);
    final snoozed = snoozedReminderCopy(
      localizations,
      fullDetails: prepared.preferences.fullDetails,
      pillName: snapshot.pillName,
    );
    final reminder = ReminderProjection(
      notificationId: id,
      projectionId: projectionId,
      occurrenceId: occurrence.id,
      userId: identity.$1,
      sessionGeneration: identity.$2,
      identity: projectionIdentity,
      stateVersion: projectionIdentity == null ? null : occurrence.stateVersion,
      scheduledAtUtc: _clock().toUtc().add(delay),
      timeZone: occurrence.timeZone,
      title: snoozed.title,
      body: snoozed.body,
      allowCareActions: prepared.preferences.fullDetails,
      payload: jsonEncode({
        if (projectionIdentity != null) ...projectionIdentity.toJson(),
        'occurrenceId': occurrence.id,
        'projectionId': projectionId,
        'userId': identity.$1,
        'sessionGeneration': identity.$2,
        if (projectionIdentity != null) 'stateVersion': occurrence.stateVersion,
      }),
    );
    return serializeNotificationWork(
      () => _effects(() async {
        await _preferences.reload();
        await _platform.initialize();
        if (!await _preparedIsCurrent(
          _ReconcileRequest(
            identity: identity,
            locale: null,
            projectionIdentity: projectionIdentity,
          ),
          prepared,
        )) {
          return false;
        }
        if (!reminder.scheduledAtUtc.isAfter(_clock().toUtc())) return false;
        final registry = _readRegistry();
        final stored = registry[id];
        final pending = {
          for (final item in await _platform.pendingRequests()) item.id: item,
        };
        final actual = pending[id];
        if (_platformKind == ReminderPlatformKind.android &&
            actual == null &&
            pending.length >= _androidSnoozeAdmissionLimit) {
          return false;
        }
        if ((stored != null && stored['projectionId'] != projectionId) ||
            (actual != null &&
                _payloadProjectionId(actual.payload) != projectionId)) {
          return false;
        }
        // Headless admission is checked after all preparation and immediately
        // before publishing this effect. OS work never holds the app-lock gate.
        await requireEffectAdmission?.call();
        await _recordInLedger([id]);
        registry[id] = {
          ...reminder.toRegistryEntry(),
          'kind': 'snooze',
          'publicationPending': true,
          'publicationPendingAt': _clock().toUtc().toIso8601String(),
        };
        await _persistRegistry(registry);
        await _platform.schedule(reminder, localizations: localizations);
        if (!await _preparedIsCurrent(
          _ReconcileRequest(
            identity: identity,
            locale: null,
            projectionIdentity: projectionIdentity,
          ),
          prepared,
        )) {
          await _platform.cancel(id);
          registry.remove(id);
          await _persistRegistry(registry);
          return false;
        }
        registry[id] = {...reminder.toRegistryEntry(), 'kind': 'snooze'};
        await _persistRegistry(registry);
        return true;
      }),
    );
  }

  Future<_CareSnapshot?> _readCareSnapshot(
    _ReconcileRequest request, {
    bool materialize = false,
  }) async {
    final identity = request.identity;
    Future<_CareSnapshot> read() async {
      final activeProfiles = await _eligibleProfiles(identity.$1);
      final occurrenceRows = await _database
          .customSelect(
            "SELECT * FROM medication_occurrences WHERE user_id=? AND source='scheduled' AND provenance='exact' AND state='pending' AND superseded_at IS NULL",
            variables: [Variable<String>(identity.$1)],
            readsFrom: {_database.medicationOccurrences},
          )
          .get();
      final occurrences = occurrenceRows
          .map((row) => _database.medicationOccurrences.map(row.data))
          .toList();
      final activeProfileIds = {
        for (final profile in activeProfiles) profile.id,
      };
      final activePills = [
        for (final profile in activeProfiles)
          ...await _database.pillsDao.getByProfileId(profile.id),
      ];
      final activePillIds = {
        for (final pill in activePills)
          if (!pill.isPrn) pill.id,
      };
      final activeSchedules = [
        for (final schedule
            in await _database.schedulesDao.getActiveSchedules())
          if (activePillIds.contains(schedule.pillId)) schedule,
      ];
      final pillsById = {
        for (final pill in activePills)
          if (!pill.isPrn) pill.id: pill,
      };
      final schedulesById = {
        for (final schedule in activeSchedules) schedule.id: schedule,
      };
      final eligibleOccurrences = occurrences
          .where(
            (occurrence) => isEligibleReminderOccurrence(
              occurrence,
              pillsById: pillsById,
              schedulesById: schedulesById,
              ownerId: identity.$1,
              workspaceId: request.projectionIdentity?.workspaceId,
            ),
          )
          .toList();
      final context = _access == null
          ? null
          : await request.projectionIdentity?.resolve(_access);
      final reminderPreferences = context == null
          ? ReminderPreferences()
          : await ReminderPreferencesRepository(
              database: _database,
              access: _access!,
              context: context,
            ).load();
      eligibleOccurrences.removeWhere(
        (row) => !reminderPreferences.choiceFor(row.scheduleId).enabled,
      );
      final fingerprint = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                reminderPreferences.toJson(),
                (activeProfiles.toList()..sort((a, b) => a.id.compareTo(b.id)))
                    .map((row) => row.toJson())
                    .toList(),
                (activePills.toList()..sort((a, b) => a.id.compareTo(b.id)))
                    .map((row) => row.toJson())
                    .toList(),
                (activeSchedules.toList()..sort((a, b) => a.id.compareTo(b.id)))
                    .map((row) => row.toJson())
                    .toList(),
                (occurrences.toList()..sort((a, b) => a.id.compareTo(b.id)))
                    .map((row) => row.toJson())
                    .toList(),
              ]),
            ),
          )
          .toString();
      final currentNames = {for (final pill in activePills) pill.id: pill.name};
      return _CareSnapshot(
        activeProfileIds,
        [
          for (final occurrence in eligibleOccurrences)
            withCurrentName(occurrence, currentNames),
        ],
        fingerprint,
        reminderPreferences,
      );
    }

    final access = _access;
    if (access == null) return _database.transaction(read);
    final context = await request.projectionIdentity?.resolve(access);
    if (context == null) return null;
    try {
      return await access.withGrant(context, () async {
        final now = _clock().toUtc();
        if (materialize) {
          await RoutineRepository(
            database: _database,
            access: access,
            context: context,
            clock: _clock,
          ).ensureMaterialized(
            fromLocalDate: routineDateKey(
              now.subtract(const Duration(days: 1)),
            ),
            throughLocalDate: routineDateKey(now.add(const Duration(days: 31))),
          );
        }
        return read();
      });
    } on WorkspaceAccessFailure {
      return null;
    }
  }

  Future<_PreparedReminders?> _prepare(
    _ReconcileRequest request, {
    bool materialize = true,
  }) async {
    final snapshot = await _readCareSnapshot(request, materialize: materialize);
    if (snapshot == null) return null;
    final localizations = await _resolveLocalizations(request.locale);
    final batch = const ReminderProjectionBuilder().build(
      records: [
        for (final occurrence in snapshot.occurrences)
          MedicationOccurrenceRecord(occurrence: occurrence, events: const []),
      ],
      activeProfileIds: snapshot.activeProfileIds,
      userId: request.identity.$1,
      sessionGeneration: request.identity.$2,
      now: _clock(),
      platform: _platformKind,
      localizations: localizations,
      identity: request.projectionIdentity,
      preferences: snapshot.preferences,
    );
    return _PreparedReminders(
      localizations,
      snapshot.activeProfileIds,
      snapshot.occurrences,
      batch,
      snapshot.fingerprint,
      snapshot.preferences,
    );
  }

  Future<(int, int)> _careRevision() async {
    final row = await _database
        .customSelect(
          'SELECT total_changes() AS local_changes, data_version AS external_changes '
          'FROM pragma_data_version',
        )
        .getSingle();
    return (row.read<int>('local_changes'), row.read<int>('external_changes'));
  }

  Future<bool> _preparedIsCurrent(
    _ReconcileRequest request,
    _PreparedReminders prepared,
  ) async {
    if (!await _isCurrent(request.identity, request.projectionIdentity)) {
      return false;
    }
    final current = await _readCareSnapshot(request);
    return current?.fingerprint == prepared.fingerprint;
  }

  /// Retention is independent of action migration. Android exposes visible
  /// content and ID, while exact grant/projection authority comes from our
  /// protected registry and current occurrence, never from the tray itself.
  Future<Set<int>> _verifiedDeliveredReminderIds(
    _ReconcileRequest request,
    _PreparedReminders prepared,
    Map<int, Map<String, Object?>> registry,
  ) async {
    final platform = _platform;
    final access = _access;
    final identity = request.projectionIdentity;
    if (platform is! ActiveReminderNotificationPlatform ||
        access == null ||
        identity == null) {
      return const {};
    }
    final context = await identity.resolve(access);
    if (context == null) return const {};
    final repository = MedicationRepository(
      _database,
      access: access,
      context: context,
    );
    final occurrences = {for (final row in prepared.occurrences) row.id: row};
    final retained = <int>{};
    for (final active
        in await (platform as ActiveReminderNotificationPlatform)
            .activeReminders()) {
      final entry = registry[active.id];
      if (active.tag != null ||
          (active.channelId != null &&
              !isKnownReminderChannelId(active.channelId!)) ||
          entry == null ||
          !ProjectionRegistry.isReminder(entry) ||
          !_owns(entry, request.identity, identity) ||
          entry['id'] != active.id ||
          entry['publicationPending'] == true ||
          entry['allowCareActions'] != prepared.preferences.fullDetails) {
        continue;
      }
      final occurrence = occurrences[entry['occurrenceId']];
      final projectionId = entry['projectionId'];
      final version = entry['stateVersion'];
      final rawAt = entry['scheduledAtUtc'];
      final at = rawAt is String ? DateTime.tryParse(rawAt) : null;
      if (occurrence == null ||
          projectionId is! String ||
          version is! int ||
          at == null ||
          at.isAfter(_clock().toUtc()) ||
          !notificationIdMatchesProjection(projectionId, active.id) ||
          occurrence.stateVersion != version ||
          occurrence.state != 'pending' ||
          occurrence.supersededAt != null ||
          !prepared.preferences.choiceFor(occurrence.scheduleId).enabled) {
        continue;
      }
      final kinds = entry['kind'] == 'snooze'
          ? ['snooze']
          : [
              'reminder',
              for (final offset
                  in prepared.preferences
                      .choiceFor(occurrence.scheduleId)
                      .followUpMinutes)
                followUpReminderKind(offset),
            ];
      final kind = kinds
          .where(
            (kind) =>
                reminderProjectionId(
                  userId: identity.ownerId,
                  sessionGeneration: identity.grantEpoch,
                  occurrenceId: occurrence.id,
                  kind: kind,
                  workspaceId: identity.workspaceId,
                  grantEpoch: identity.grantEpoch,
                  stateVersion: version,
                ) ==
                projectionId,
          )
          .firstOrNull;
      if (kind == null) continue;
      // Private Open-only alerts reuse protected parent/person eligibility;
      // notification schedule and privacy choices were checked above.
      final allowed = prepared.preferences.fullDetails
          ? await repository.isCurrentReminderActionForReview(
              occurrenceId: occurrence.id,
              projectionId: projectionId,
              kind: kind,
              deliveredStateVersion: version,
            )
          : await repository.isCurrentWidgetActionForReview(
              occurrenceId: occurrence.id,
              projectionId: reminderProjectionId(
                userId: identity.ownerId,
                sessionGeneration: identity.grantEpoch,
                occurrenceId: occurrence.id,
                kind: 'widget',
                workspaceId: identity.workspaceId,
                grantEpoch: identity.grantEpoch,
                stateVersion: version,
              ),
              deliveredStateVersion: version,
            );
      if (!allowed) continue;
      final schedule = decodeScheduleSnapshot(
        jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>,
      );
      final snoozed = snoozedReminderCopy(
        prepared.localizations,
        fullDetails: prepared.preferences.fullDetails,
        pillName: schedule.pillName,
      );
      final expected = kind == 'snooze'
          ? ReminderProjection(
              notificationId: active.id,
              projectionId: projectionId,
              occurrenceId: occurrence.id,
              userId: identity.ownerId,
              sessionGeneration: identity.grantEpoch,
              scheduledAtUtc: at,
              timeZone: occurrence.timeZone,
              title: snoozed.title,
              body: snoozed.body,
              payload: jsonEncode({
                ...identity.toJson(),
                'occurrenceId': occurrence.id,
                'projectionId': projectionId,
                'userId': identity.ownerId,
                'sessionGeneration': identity.grantEpoch,
                'stateVersion': version,
              }),
              allowCareActions: prepared.preferences.fullDetails,
            )
          : const ReminderProjectionBuilder()
                .build(
                  records: [
                    MedicationOccurrenceRecord(
                      occurrence: occurrence,
                      events: const [],
                    ),
                  ],
                  activeProfileIds: prepared.activeProfileIds,
                  userId: identity.ownerId,
                  sessionGeneration: identity.grantEpoch,
                  now: at.subtract(const Duration(microseconds: 1)),
                  platform: _platformKind,
                  localizations: prepared.localizations,
                  identity: identity,
                  preferences: prepared.preferences,
                )
                .reminders
                .where((row) => row.projectionId == projectionId)
                .firstOrNull;
      if (expected == null ||
          active.title != expected.title ||
          active.body != expected.body ||
          (active.payload != null && active.payload != expected.payload)) {
        continue;
      }
      retained.add(active.id);
    }
    await access.requireCurrent(context);
    return retained;
  }

  Future<Set<int>> _verifiedActiveActionIds(
    _ReconcileRequest request,
    _PreparedReminders prepared,
    Map<int, Map<String, Object?>> registry,
  ) async {
    final access = _access;
    final identity = request.projectionIdentity;
    if (access == null ||
        identity == null ||
        request.activeActionsToRetain.isEmpty ||
        !prepared.preferences.fullDetails) {
      return const {};
    }
    final context = await identity.resolve(access);
    if (context == null) return const {};
    final repository = MedicationRepository(
      _database,
      access: access,
      context: context,
    );
    final occurrences = {
      for (final occurrence in prepared.occurrences) occurrence.id: occurrence,
    };
    final retained = <int>{};
    for (final candidate in request.activeActionsToRetain) {
      final entry = registry[candidate.notificationId];
      final occurrence = occurrences[candidate.occurrenceId];
      if (entry == null ||
          occurrence == null ||
          candidate.identity != identity ||
          !_owns(entry, request.identity, identity) ||
          entry['id'] != candidate.notificationId ||
          entry['projectionId'] != candidate.projectionId ||
          entry['occurrenceId'] != candidate.occurrenceId ||
          entry['stateVersion'] != candidate.stateVersion ||
          entry['allowCareActions'] != true ||
          occurrence.userId != request.identity.$1 ||
          occurrence.source != 'scheduled' ||
          !occurrence.expected ||
          occurrence.provenance != 'exact' ||
          occurrence.state != 'pending' ||
          occurrence.supersededAt != null ||
          occurrence.stateVersion != candidate.stateVersion ||
          occurrence.pillId == null ||
          occurrence.scheduleId == null ||
          !notificationIdMatchesProjection(
            candidate.projectionId,
            candidate.notificationId,
          ) ||
          reminderProjectionId(
                userId: identity.ownerId,
                sessionGeneration: identity.grantEpoch,
                occurrenceId: candidate.occurrenceId,
                kind: candidate.kind,
                workspaceId: identity.workspaceId,
                grantEpoch: identity.grantEpoch,
                stateVersion: candidate.stateVersion,
              ) !=
              candidate.projectionId) {
        continue;
      }
      final followUpMinutes = isFollowUpReminderKind(candidate.kind)
          ? int.tryParse(candidate.kind.split(':').last)
          : null;
      if (followUpMinutes != null &&
          !prepared.preferences
              .choiceFor(occurrence.scheduleId)
              .followUpMinutes
              .contains(followUpMinutes)) {
        continue;
      }
      try {
        final schedule = decodeScheduleSnapshot(
          jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>,
        );
        if (!snapshotOwns(schedule, identity.ownerId, identity.workspaceId) ||
            !prepared.activeProfileIds.contains(schedule.profileId) ||
            schedule.frequency == 'prn' ||
            schedule.timeZone != occurrence.timeZone) {
          continue;
        }
      } on Object {
        continue;
      }
      if (await repository.isCurrentReminderActionForReview(
        occurrenceId: candidate.occurrenceId,
        projectionId: candidate.projectionId,
        kind: candidate.kind,
        deliveredStateVersion: candidate.stateVersion,
      )) {
        retained.add(candidate.notificationId);
      }
    }
    return retained;
  }

  Future<ProjectionReconciliationReport> _reconcileOne(
    _ReconcileRequest request,
    _PreparedReminders prepared,
  ) async {
    final identity = request.identity;
    var failureCount = 0;
    var scheduledCount = 0;
    var availableCount = 0;
    var invalidCount = 0;
    var desiredCount = 0;
    var coverageShortened = false;
    late final Map<int, Map<String, Object?>> registry;

    // AppDatabase keeps one SQLite connection (also behind its Drift isolate).
    // Its own writes change total_changes(); commits from another engine change
    // data_version. Neither counter alone covers both kinds of writer.
    // Cache only within this pass, and only across a stable full validation.
    // This avoids re-reading and hashing every occurrence around every alarm.
    (int, int)? validatedRevision;
    Future<bool> current() async {
      if (!await _isCurrent(identity, request.projectionIdentity)) return false;
      final before = await _careRevision();
      if (before == validatedRevision) return true;
      if (!await _preparedIsCurrent(request, prepared)) return false;
      final after = await _careRevision();
      if (before != after) return false;
      validatedRevision = after;
      return true;
    }

    bool generationChanged = false;
    try {
      registry = _readRegistry();
      if (!await current()) {
        generationChanged = true;
        return _report(
          identity,
          state: ProjectionReconciliationState.degraded,
          desiredCount: 0,
          scheduledCount: 0,
          failureCount: 1,
          availableCount: 0,
          invalidCount: 0,
        );
      }
      final preservedActiveIds = {
        ...await _verifiedDeliveredReminderIds(request, prepared, registry),
        ...await _verifiedActiveActionIds(request, prepared, registry),
      };
      if (!await _platform.hasExactAlarmPermission() ||
          !await _platform.hasNotificationPermission()) {
        failureCount++;
        // Permission loss cannot keep an already completed or disabled dose's
        // alert alive. Retain still-desired alerts; cancel only proven stale
        // effects from this exact captured grant.
        final pending = {
          for (final item in await _platform.pendingRequests()) item.id: item,
        };
        final desiredById = <int, ReminderProjection>{
          for (final reminder in prepared.batch.reminders)
            reminder.notificationId: reminder,
        };
        desiredById.addAll(
          planActiveSnoozes(
            registry: registry,
            pendingById: pending,
            occurrences: prepared.occurrences,
            activeProfileIds: prepared.activeProfileIds,
            identity: identity,
            projectionIdentity: request.projectionIdentity,
            preferences: prepared.preferences,
            localizations: prepared.localizations,
            now: _clock(),
            owns: (value) => _owns(value, identity, request.projectionIdentity),
          ),
        );
        final desired = privacySafeReminderIds(
          desiredById,
          pendingById: pending,
          registry: registry,
        )..addAll(preservedActiveIds);
        final stale = {
          for (final item in registry.entries)
            if (ProjectionRegistry.isReminder(item.value) &&
                _owns(item.value, identity, request.projectionIdentity))
              item.key,
          for (final item in pending.entries)
            if (_isReminderPayload(item.value.payload) &&
                _ownsPayload(
                  item.value.payload,
                  identity,
                  request.projectionIdentity,
                ))
              item.key,
        }.difference(desired);
        for (final id in stale) {
          if (!await current()) break;
          final actual = pending[id];
          if (actual != null &&
              !_ownsPayload(
                actual.payload,
                identity,
                request.projectionIdentity,
              )) {
            continue;
          }
          await _platform.cancel(id);
          registry.remove(id);
          await _persistRegistry(registry);
        }
        return await _persistReport(
          identity,
          state: ProjectionReconciliationState.degraded,
          desiredCount: 0,
          scheduledCount: 0,
          failureCount: failureCount,
          availableCount: 0,
          invalidCount: 0,
        );
      }

      await _platform.initialize();
      if (!await current()) {
        generationChanged = true;
        return _report(
          identity,
          state: ProjectionReconciliationState.degraded,
          desiredCount: 0,
          scheduledCount: 0,
          failureCount: 1,
          availableCount: 0,
          invalidCount: 0,
        );
      }

      final localizations = prepared.localizations;
      final activeProfileIds = prepared.activeProfileIds;
      final eligibleOccurrences = prepared.occurrences;
      final batch = prepared.batch;
      final pendingById = {
        for (final request in await _platform.pendingRequests())
          request.id: request,
      };
      // A reminder keeps the id it already holds; ids held by anything else
      // (another owner, a snooze, low stock, readiness) are not reused.
      final preferredIds = <String, int>{};
      final occupiedIds = <int>{};
      for (final entry in registry.entries) {
        if (ProjectionRegistry.isReminder(entry.value) &&
            _owns(entry.value, identity, request.projectionIdentity)) {
          final projection = entry.value['projectionId'];
          if (projection is String) preferredIds[projection] = entry.key;
        } else {
          occupiedIds.add(entry.key);
        }
      }
      for (final entry in pendingById.entries) {
        if (_isReminderPayload(entry.value.payload) &&
            _ownsPayload(
              entry.value.payload,
              identity,
              request.projectionIdentity,
            )) {
          final projection = _payloadProjectionId(entry.value.payload);
          if (projection != null) preferredIds[projection] = entry.key;
        } else {
          occupiedIds.add(entry.key);
        }
      }
      var droppedReminders = 0;
      final stableReminders = stabilizeReminderIds(
        batch.reminders,
        preferred: preferredIds,
        occupied: occupiedIds,
        onDropped: (count) => droppedReminders = count,
      );
      final futureReminders = stableReminders
          .where((item) => item.scheduledAtUtc.isAfter(_clock().toUtc()))
          .toList();
      desiredCount = futureReminders.length;
      availableCount = batch.availableCount;
      invalidCount = batch.invalidOccurrenceCount + droppedReminders;
      coverageShortened = batch.coverageShortened;
      final desiredById = {
        for (final reminder in futureReminders)
          reminder.notificationId: reminder,
      };
      final activeSnoozes = planActiveSnoozes(
        registry: registry,
        pendingById: pendingById,
        occurrences: eligibleOccurrences,
        activeProfileIds: activeProfileIds,
        identity: identity,
        projectionIdentity: request.projectionIdentity,
        preferences: prepared.preferences,
        localizations: localizations,
        now: _clock(),
        owns: (value) => _owns(value, identity, request.projectionIdentity),
      );
      desiredById.addAll(activeSnoozes);
      final semanticDesired = {
        // Include reminders that became due since preparation. They remain
        // valid delivered care even though they no longer need a future alarm.
        for (final reminder in stableReminders)
          reminder.notificationId: reminder,
        ...activeSnoozes,
      };
      if (_platformKind == ReminderPlatformKind.android) {
        final otherPending = pendingById.values
            .where(
              (item) =>
                  !_isReminderPayload(item.payload) ||
                  !_ownsPayload(
                    item.payload,
                    identity,
                    request.projectionIdentity,
                  ),
            )
            .length;
        final share = await _androidWorkspaceBudget();
        final budget = androidAdmissionBudget(
          otherPendingCount: otherPending,
          workspaceShare: share,
        );
        final selection = selectWithinAndroidBudget(desiredById, budget);
        if (selection.shortened) {
          coverageShortened = true;
          desiredById
            ..clear()
            ..addAll(selection.selected);
        }
      }
      desiredCount = desiredById.length;
      final collected = request.collector?.desired;
      if (collected != null) {
        for (final entry in [
          ...semanticDesired.entries,
          ...desiredById.entries,
        ]) {
          (collected[entry.key] ??= {}).add(entry.value.projectionId);
        }
      }
      request.collector?.preserved.addAll(preservedActiveIds);
      await _recordInLedger(desiredById.keys);

      // Capacity eviction is separate from semantic cancellation: only future
      // owned alarms may be displaced. Delivered notifications remain visible.
      // Retire obsolete alarms first as well, so a full device can admit the
      // next nearest reminder without exceeding its native alarm limit.
      if (_platformKind == ReminderPlatformKind.android) {
        for (final entry in pendingById.entries.toList()) {
          final id = entry.key;
          if (desiredById.containsKey(id) ||
              preservedActiveIds.contains(id) ||
              !_isReminderPayload(entry.value.payload) ||
              !_ownsPayload(
                entry.value.payload,
                identity,
                request.projectionIdentity,
              )) {
            continue;
          }
          final displaced = semanticDesired[id];
          if (displaced != null &&
              (_payloadProjectionId(entry.value.payload) !=
                      displaced.projectionId ||
                  !displaced.scheduledAtUtc.isAfter(_clock().toUtc()))) {
            continue;
          }
          if (!await current()) {
            generationChanged = true;
            break;
          }
          // The current-care check can take time. Never withdraw a valid alert
          // that became due while that check was running.
          if (displaced != null &&
              !displaced.scheduledAtUtc.isAfter(_clock().toUtc())) {
            continue;
          }
          try {
            await _platform.cancel(id);
            registry.remove(id);
            pendingById.remove(id);
            await _persistRegistry(registry);
          } on Object catch (error) {
            failureCount++;
            AppLogger.warning(
              'ProjectionReconciler',
              'Reminder retirement failed: ${error.runtimeType}',
            );
          }
        }
      }

      final desiredProjections = {
        for (final item in semanticDesired.values) item.projectionId,
      };
      for (final reminder in desiredById.values) {
        if (generationChanged) break;
        if (!reminder.scheduledAtUtc.isAfter(_clock().toUtc())) {
          failureCount++;
          continue;
        }
        var stored = registry[reminder.notificationId];
        var actual = pendingById[reminder.notificationId];
        // An alarm of this workspace's own, for a projection nothing wants
        // any more, sits on the id: retire it, then schedule onto the id.
        final occupantProjection =
            (stored != null &&
                ProjectionRegistry.isReminder(stored) &&
                _owns(stored, identity, request.projectionIdentity))
            ? stored['projectionId']
            : actual != null &&
                  _isReminderPayload(actual.payload) &&
                  _ownsPayload(
                    actual.payload,
                    identity,
                    request.projectionIdentity,
                  )
            ? _payloadProjectionId(actual.payload)
            : null;
        if (occupantProjection != null &&
            occupantProjection != reminder.projectionId &&
            !desiredProjections.contains(occupantProjection) &&
            !preservedActiveIds.contains(reminder.notificationId)) {
          if (!await current()) {
            generationChanged = true;
            break;
          }
          try {
            await _platform.cancel(reminder.notificationId);
            registry.remove(reminder.notificationId);
            pendingById.remove(reminder.notificationId);
            await _persistRegistry(registry);
            stored = null;
            actual = null;
          } on Object catch (error) {
            failureCount++;
            AppLogger.warning(
              'ProjectionReconciler',
              'Stale occupant retirement failed: ${error.runtimeType}',
            );
            continue;
          }
        }
        if ((stored != null &&
                stored['projectionId'] != reminder.projectionId) ||
            (actual != null &&
                _payloadProjectionId(actual.payload) !=
                    reminder.projectionId)) {
          failureCount++;
          continue;
        }
        final alreadyCurrent =
            stored != null &&
            stored['projectionId'] == reminder.projectionId &&
            stored['userId'] == identity.$1 &&
            stored['sessionGeneration'] == identity.$2 &&
            stored['publicationPending'] != true &&
            actual != null &&
            actual.payload == reminder.payload &&
            actual.title == reminder.title &&
            actual.body == reminder.body &&
            // A reminder scheduled for an older channel revision is stale
            // even when its copy is unchanged: it must move to the current
            // channel. Entries from before versioning are revision 1.
            (stored['channelRevision'] ?? 1) == kReminderChannelRevision &&
            (stored['allowCareActions'] ?? true) == reminder.allowCareActions &&
            (!reminder.allowCareActions ||
                stored['actionPresentationVersion'] ==
                    reminderActionPresentationVersion);
        if (alreadyCurrent) {
          scheduledCount++;
          continue;
        }
        if (_platformKind == ReminderPlatformKind.android &&
            actual == null &&
            pendingById.length >= androidReminderBudget) {
          // Failed retirement or an unverified envelope must not result in
          // repeatedly attempting an over-capacity native publication.
          failureCount++;
          continue;
        }
        if (!await current()) {
          generationChanged = true;
          break;
        }
        try {
          final entry = {
            ...reminder.toRegistryEntry(),
            if (activeSnoozes.containsKey(reminder.notificationId))
              'kind': 'snooze',
          };
          registry[reminder.notificationId] = {
            ...entry,
            'publicationPending': true,
            'publicationPendingAt': _clock().toUtc().toIso8601String(),
          };
          await _persistRegistry(registry);
          await _platform.schedule(reminder, localizations: localizations);
          if (!await current()) {
            generationChanged = true;
            try {
              await _platform.cancel(reminder.notificationId);
            } on Object {
              failureCount++;
            }
            break;
          }
          scheduledCount++;
          registry[reminder.notificationId] = entry;
          pendingById[reminder.notificationId] = PlatformReminderRequest(
            id: reminder.notificationId,
            title: reminder.title,
            body: reminder.body,
            payload: reminder.payload,
          );
          await _persistRegistry(registry);
        } on Object catch (error) {
          failureCount++;
          AppLogger.warning(
            'ProjectionReconciler',
            'Reminder scheduling failed: ${error.runtimeType}',
          );
        }
      }

      if (!generationChanged && await current()) {
        // Scheduling another dose can fail without reviving completed alerts.
        // An exposed old effect is unsafe to retain after a privacy change,
        // including when its private replacement could not be published.
        final desiredIds = privacySafeReminderIds(
          semanticDesired,
          pendingById: pendingById,
          registry: registry,
        )..addAll(preservedActiveIds);
        final ownedIds = <int>{
          for (final entry in registry.entries)
            if (ProjectionRegistry.isReminder(entry.value) &&
                _owns(entry.value, identity, request.projectionIdentity))
              entry.key,
          for (final entry in pendingById.entries)
            if (_isReminderPayload(entry.value.payload) &&
                _ownsPayload(
                  entry.value.payload,
                  identity,
                  request.projectionIdentity,
                ))
              entry.key,
        };
        for (final id in ownedIds.difference(desiredIds)) {
          if (!await current()) {
            generationChanged = true;
            break;
          }
          try {
            final actual = pendingById[id];
            if (actual != null &&
                !_ownsPayload(
                  actual.payload,
                  identity,
                  request.projectionIdentity,
                )) {
              registry.remove(id);
              await _persistRegistry(registry);
              failureCount++;
              continue;
            }
            await _platform.cancel(id);
            registry.remove(id);
            pendingById.remove(id);
            await _persistRegistry(registry);
          } on Object catch (error) {
            failureCount++;
            AppLogger.warning(
              'ProjectionReconciler',
              'Stale reminder cancellation failed: ${error.runtimeType}',
            );
          }
        }
      }

      if (!generationChanged && await current()) {
        final legacySucceeded = await _cancelLegacyReminders(
          desiredById.keys.toSet(),
          identity,
          request.projectionIdentity,
          pendingById,
        );
        if (!legacySucceeded) failureCount++;
      } else {
        generationChanged = true;
      }
    } on Object catch (error) {
      failureCount++;
      AppLogger.warning(
        'ProjectionReconciler',
        'Reconciliation failed: ${error.runtimeType}',
      );
    }

    if (generationChanged || !await current()) {
      return _report(
        identity,
        state: ProjectionReconciliationState.degraded,
        desiredCount: desiredCount,
        scheduledCount: scheduledCount,
        failureCount: failureCount + 1,
        availableCount: availableCount,
        invalidCount: invalidCount,
      );
    }

    final state = failureCount > 0 || invalidCount > 0
        ? ProjectionReconciliationState.degraded
        : coverageShortened
        ? ProjectionReconciliationState.coverageShortened
        : ProjectionReconciliationState.current;
    return _persistReport(
      identity,
      state: state,
      desiredCount: desiredCount,
      scheduledCount: scheduledCount,
      failureCount: failureCount,
      availableCount: availableCount,
      invalidCount: invalidCount,
    );
  }

  Future<bool> _cancelLegacyReminders(
    Set<int> desiredIds,
    SessionIdentity identity,
    ProjectionIdentity? projectionIdentity,
    Map<int, PlatformReminderRequest> pendingById,
  ) async {
    var success = true;
    final retiredIds = <int>{};
    final registeredIds = _readRegistry().keys.toSet();
    // The pre-occurrence app stored IDs per person. Later builds used pills.
    // Tombstones still prove ownership of old alarms after a person is removed.
    final ownerProfiles = await (_database.select(
      _database.profiles,
    )..where((row) => row.userId.equals(identity.$1))).get();
    final ownerPills =
        await (_database.select(_database.pills)..where(
              (row) => row.profileId.isIn(ownerProfiles.map((row) => row.id)),
            ))
            .get();
    final allowedKeys = {
      for (final profile in ownerProfiles)
        '${NotificationService.legacyIdsPreferencePrefix}${profile.id}',
      for (final pill in ownerPills)
        '${NotificationService.legacyIdsPreferencePrefix}${pill.id}',
    };
    for (final key in _preferences.getKeys().where(
      (key) => allowedKeys.contains(key),
    )) {
      final raw = _preferences.getString(key);
      if (raw == null) continue;
      try {
        final ids = (jsonDecode(raw) as List).cast<int>();
        final remaining = <int>[];
        for (final id in ids.toSet()) {
          if (desiredIds.contains(id) || registeredIds.contains(id)) continue;
          if (_isProjectionPayload(pendingById[id]?.payload) &&
              !_ownsPayload(
                pendingById[id]?.payload,
                identity,
                projectionIdentity,
              )) {
            remaining.add(id);
            success = false;
            continue;
          }
          try {
            if (!await _isCurrent(identity, projectionIdentity)) return false;
            await _platform.cancel(id);
            retiredIds.add(id);
          } on Object {
            remaining.add(id);
            success = false;
          }
        }
        if (!await _isCurrent(identity, projectionIdentity)) return false;
        if (remaining.isEmpty) {
          final removed = await _preferences.remove(key);
          if (!removed && _preferences.containsKey(key)) success = false;
        } else {
          final saved = await _preferences.setString(
            key,
            jsonEncode(remaining),
          );
          if (!saved) success = false;
        }
      } on Object {
        success = false;
      }
    }
    // Old builds could lose/overwrite their per-person ID list while Android
    // retained repeating alarms. The native pending cache is the remaining
    // evidence. Only the exact old envelope plus a retained owned schedule
    // authorizes retirement; a modern/unknown grant must never be inferred.
    final ownedScheduleIds = {
      for (final schedule
          in await (_database.select(_database.schedules)..where(
                (row) => row.pillId.isIn(ownerPills.map((pill) => pill.id)),
              ))
              .get())
        schedule.id,
    };
    for (final pending in pendingById.values) {
      if (desiredIds.contains(pending.id) ||
          registeredIds.contains(pending.id) ||
          retiredIds.contains(pending.id) ||
          !_isLegacyAlarmForSchedules(pending.payload, ownedScheduleIds)) {
        continue;
      }
      if (!await _isCurrent(identity, projectionIdentity)) return false;
      try {
        await _platform.cancel(pending.id);
      } on Object {
        // The native pending request remains evidence for the next retry.
        success = false;
      }
    }
    if (success) {
      success = await _preferences.setBool(_legacyMigrationPreferenceKey, true);
    }
    return success;
  }

  /// Device-wide retirement, never ownership assignment. Both retained legacy
  /// references must be absent across the complete protected database. A
  /// locked/foreign alias, unknown envelope or modern registry entry fences it.
  Future<void> _retireOrphanLegacyAlarms(
    List<WorkspaceContext> contexts,
  ) async {
    final access = _access;
    if (access == null) return;
    await _preferences.reload();
    const prefix = 'notif_ids_';
    final keys = _preferences
        .getKeys()
        .where((k) => k.startsWith(prefix))
        .toList();
    if (keys.isEmpty) return;
    final revision = await _careRevision();
    final parents = <String>{};
    for (final profile in await _database.select(_database.profiles).get()) {
      parents.add(profile.id);
      if (profile.serverId != null) parents.add(profile.serverId!);
    }
    for (final pill in await _database.select(_database.pills).get()) {
      parents.add(pill.id);
      if (pill.serverId != null) parents.add(pill.serverId!);
    }
    final schedules = <String>{};
    for (final schedule in await _database.select(_database.schedules).get()) {
      schedules.add(schedule.id);
      if (schedule.serverId != null) schedules.add(schedule.serverId!);
    }
    if (await _careRevision() != revision) return;
    final registeredIds = _readRegistry().keys.toSet();
    final pending = {
      for (final item in await _platform.pendingRequests()) item.id: item,
    };
    Future<bool> current() async {
      for (final context in contexts) {
        if (await ProjectionIdentity.fromContext(context).resolve(access) ==
            null) {
          return false;
        }
      }
      return await _careRevision() == revision;
    }

    final uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    for (final key in keys) {
      final owner = key.substring(prefix.length);
      if (!uuid.hasMatch(owner) || parents.contains(owner)) continue;
      final raw = _preferences.get(key);
      if (raw is! String || raw.length > 64 * 1024) continue;
      final List<int> ids;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List || decoded.any((id) => id is! int)) continue;
        ids = decoded.cast<int>();
      } on FormatException {
        continue;
      }
      final retired = <int>{};
      for (final id in ids.toSet()) {
        final request = pending[id];
        final payload = _payload(request?.payload);
        final schedule = payload is Map ? payload['scheduleId'] : null;
        if (registeredIds.contains(id) ||
            schedule is! String ||
            !uuid.hasMatch(schedule) ||
            schedules.contains(schedule) ||
            !_isLegacyAlarmForSchedules(request?.payload, {schedule})) {
          continue;
        }
        if (!await current()) break;
        try {
          await _platform.cancel(id);
          retired.add(id);
        } on Object {
          // Keep the original list entry and native request for retry.
        }
      }
      if (retired.isNotEmpty) {
        final remaining = ids.where((id) => !retired.contains(id)).toList();
        final saved = remaining.isEmpty
            ? await _preferences.remove(key)
            : await _preferences.setString(key, jsonEncode(remaining));
        if (!saved) throw StateError('Could not save legacy alarm retirement');
      }
      if (!await current()) return;
    }
  }

  bool _isLegacyAlarmForSchedules(String? raw, Set<String> scheduleIds) {
    if (raw == null || raw.length > 4096) return false;
    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      payload = decoded;
    } on FormatException {
      return false;
    }
    const keys = {
      'route',
      'scheduleId',
      'hour',
      'minute',
      'weekday',
      'pillName',
    };
    final scheduleId = payload['scheduleId'];
    final hour = payload['hour'];
    final minute = payload['minute'];
    final weekday = payload['weekday'];
    return payload.keys.every(keys.contains) &&
        payload.containsKey('weekday') &&
        scheduleId is String &&
        scheduleIds.contains(scheduleId) &&
        payload['route'] == '/home?dose=$scheduleId' &&
        hour is int &&
        hour >= 0 &&
        hour <= 23 &&
        minute is int &&
        minute >= 0 &&
        minute <= 59 &&
        (weekday == null || (weekday is int && weekday >= 1 && weekday <= 7)) &&
        (!payload.containsKey('pillName') || payload['pillName'] is String);
  }

  Map<int, Map<String, Object?>> _readRegistry() =>
      ProjectionRegistry(_preferences).read();

  Future<void> _persistRegistry(Map<int, Map<String, Object?>> registry) =>
      ProjectionRegistry(_preferences).persist(registry);

  bool _isReminderPayload(String? raw) {
    final value = _payload(raw);
    return value is Map &&
        (ProjectionRegistry.isReminder(value) ||
            (value['kind'] == null && value['occurrenceId'] is String));
  }

  bool _isProjectionPayload(String? raw) {
    if (raw == null) return false;
    try {
      final payload = jsonDecode(raw);
      return payload is Map<String, dynamic> &&
          payload['occurrenceId'] is String &&
          payload['projectionId'] is String &&
          payload['userId'] is String &&
          payload['sessionGeneration'] is int;
    } on FormatException {
      return false;
    }
  }

  Future<bool> _isCurrent(
    SessionIdentity identity, [
    ProjectionIdentity? projectionIdentity,
  ]) async {
    final access = _access;
    return access == null
        ? _generations.isCurrent(userId: identity.$1, generation: identity.$2)
        : projectionIdentity != null &&
              await projectionIdentity.resolve(access) != null;
  }

  bool _owns(
    Object? value,
    SessionIdentity identity,
    ProjectionIdentity? projectionIdentity,
  ) => projectionIdentity != null
      ? projectionIdentity.owns(value)
      : value is Map &&
            value['version'] == null &&
            value['userId'] == identity.$1 &&
            value['sessionGeneration'] == identity.$2;
  Object? _payload(String? raw) {
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  bool _ownsPayload(
    String? raw,
    SessionIdentity identity,
    ProjectionIdentity? projectionIdentity,
  ) => _owns(_payload(raw), identity, projectionIdentity);
  String? _payloadProjectionId(String? raw) {
    final value = _payload(raw);
    return value is Map ? value['projectionId'] as String? : null;
  }

  /// Recover retirement interrupted after the durable grant was revoked. All
  /// identities are validated before any cancellation; unknown metadata stays.
  ///
  /// One identity that cannot be judged or retired (an unrecognised grant, a
  /// locked workspace, a failing cancel) is skipped and counted, never allowed
  /// to abort the rest. Returns how many identities were skipped.
  Future<int> retireUnavailable() => serializeNotificationWork(
    () => _effects(() async {
      final access = _access;
      if (access == null) return 0;
      await _preferences.reload();
      final registry = _readRegistry();
      await _platform.initialize();
      final pending = {
        for (final request in await _platform.pendingRequests())
          request.id: request,
      };
      final identities = <ProjectionIdentity>{
        for (final entry in registry.values)
          if (ProjectionIdentity.fromJson(entry)
              case final ProjectionIdentity identity)
            identity,
        for (final request in pending.values)
          if (ProjectionIdentity.fromJson(_payload(request.payload))
              case final ProjectionIdentity identity)
            identity,
      };
      var skipped = 0;
      final retired = <ProjectionIdentity>{};
      for (final identity in identities) {
        try {
          if (await identity.retirementRequired(access)) retired.add(identity);
        } on Object catch (error) {
          skipped++;
          AppLogger.warning(
            'ProjectionReconciler',
            'Projection identity not judged: ${error.runtimeType}',
          );
        }
      }
      for (final identity in retired) {
        try {
          await _retireCaptured(identity, registry, pending);
        } on Object catch (error) {
          skipped++;
          AppLogger.warning(
            'ProjectionReconciler',
            'Projection identity not retired: ${error.runtimeType}',
          );
        }
      }
      return skipped;
    }),
  );

  Future<void> _retireCaptured(
    ProjectionIdentity identity,
    Map<int, Map<String, Object?>> registry,
    Map<int, PlatformReminderRequest> pending,
  ) async {
    final ids = {
      for (final item in registry.entries)
        if (identity.owns(item.value)) item.key,
      for (final item in pending.entries)
        if (identity.owns(_payload(item.value.payload))) item.key,
    };
    for (final id in ids) {
      final actual = pending[id];
      if (actual == null || identity.owns(_payload(actual.payload))) {
        await _platform.cancel(id);
        pending.remove(id);
      }
      if (identity.owns(registry[id])) registry.remove(id);
      await _persistRegistry(registry);
    }
  }

  Future<void> retire(ProjectionIdentity identity) => serializeNotificationWork(
    () => _effects(() async {
      await _preferences.reload();
      await _platform.initialize();
      final registry = _readRegistry();
      final pending = {
        for (final request in await _platform.pendingRequests())
          request.id: request,
      };
      await _retireCaptured(identity, registry, pending);
    }),
  );

  /// Clears the reminders this app set on the phone and sets them again from
  /// the care data. Care data, history and settings are never touched.
  ///
  /// The desired set is built for every workspace first, and nothing is
  /// cancelled unless all of them can be rebuilt. Only reminder alarms go:
  /// pending snoozes, low-stock alerts and the readiness test stay armed with
  /// their registry entries. Every id the ledger and the legacy `notif_ids_*`
  /// lists remember is cancelled before those records are wiped, so a ghost
  /// from an earlier build cannot outlive its bookkeeping, and a list whose
  /// ids could not all be cancelled is kept for the next audit. A corrupt
  /// registry that every normal pass refuses to touch is replaced here too.
  ///
  /// [rebuild] runs the all-workspace pass; pass the runner's so a busy or
  /// degraded first attempt keeps retrying in the background. An unhealthy
  /// first rebuild is reported as [ReminderResetFailure.rebuild] with
  /// `restoring` set when that retry is underway.
  Future<ReminderResetResult> resetReminders({
    Locale? locale,
    Future<void> Function()? recheckStock,
    Future<ReconcileAllResult> Function()? rebuild,
    Future<void> Function()? scheduleRetry,
  }) async {
    final access = _access;
    if (access == null) {
      return const ReminderResetResult.failed(ReminderResetFailure.unavailable);
    }
    final signedOutOwners = <String>{};
    try {
      if (!await _platform.hasExactAlarmPermission() ||
          !await _platform.hasNotificationPermission()) {
        return const ReminderResetResult.failed(
          ReminderResetFailure.permission,
        );
      }
      await access.workspaces.ensureLocal();
      final workspaces = await _database.select(_database.careWorkspaces).get();
      var buildable = workspaces.isNotEmpty;
      for (final workspace in workspaces) {
        final context = await access.contextForOwner(workspace.ownerUserId);
        if (context == null) {
          // Signed out here: nothing to rebuild, and nothing of it is touched.
          signedOutOwners.add(workspace.ownerUserId);
          continue;
        }
        final prepared = await _prepare(
          _ReconcileRequest(
            identity: (context.ownerUserId, context.accessEpoch),
            locale: locale,
            projectionIdentity: ProjectionIdentity.fromContext(context),
          ),
        );
        if (prepared == null) {
          buildable = false;
          break;
        }
      }
      if (!buildable) {
        return const ReminderResetResult.failed(ReminderResetFailure.prepare);
      }
    } on Object catch (error) {
      AppLogger.warning(
        'ProjectionReconciler',
        'Reminder reset could not prepare: ${error.runtimeType}',
      );
      return const ReminderResetResult.failed(ReminderResetFailure.prepare);
    }

    var removed = 0;
    var clearFailures = 0;
    var registryUnreadable = false;
    try {
      await serializeNotificationWork(
        () => _effects(() async {
          await _preferences.reload();
          await _platform.initialize();
          final Map<int, Map<String, Object?>> registry;
          try {
            registry = _readRegistry();
          } on FormatException {
            // A snooze payload is not told apart from a reminder's without the
            // registry; cancelling blind could drop a pending snooze.
            registryUnreadable = true;
            return;
          }
          bool keptKind(Object? kind) =>
              kind == 'snooze' || kind == 'lowStock' || kind == 'readiness';
          final pending = await _platform.pendingRequests();
          bool signedOut(int id, Object? payload) {
            final owner =
                (payload is Map ? payload['userId'] : null) ??
                registry[id]?['userId'];
            return owner is String && signedOutOwners.contains(owner);
          }

          final kept = <int>{
            for (final entry in registry.entries)
              if (keptKind(entry.value['kind']) ||
                  signedOut(entry.key, entry.value))
                entry.key,
          };
          final doomed = <int>{};
          for (final request in pending) {
            final payload = _payload(request.payload);
            if (kept.contains(request.id) ||
                (payload is Map && keptKind(payload['kind'])) ||
                signedOut(request.id, payload)) {
              continue;
            }
            doomed.add(request.id);
          }
          Future<bool> cancel(int id) async {
            try {
              await _platform.cancel(id);
              return true;
            } on Object catch (error) {
              clearFailures++;
              AppLogger.warning(
                'ProjectionReconciler',
                'Reminder reset cancel failed: ${error.runtimeType}',
              );
              return false;
            }
          }

          final failedIds = <int>{};
          for (final id in doomed) {
            if (!await cancel(id)) failedIds.add(id);
          }
          removed = doomed.length - failedIds.length;
          // Ids the ledger and the old per-person lists remember are cancelled
          // by number, then forgotten only if every cancel held.
          final ledgerIds = ReminderIdLedger(_preferences).read().keys.toSet();
          var ledgerClean = true;
          for (final id in ledgerIds) {
            if (kept.contains(id) || doomed.contains(id)) continue;
            if (!await cancel(id)) ledgerClean = false;
          }
          for (final key in _preferences.getKeys().toList()) {
            if (!key.startsWith(_legacyIdsPreferencePrefix)) continue;
            final raw = _preferences.getString(key);
            var clean = true;
            try {
              final decoded = raw == null ? null : jsonDecode(raw);
              if (decoded is List) {
                for (final id in decoded.whereType<int>().toSet()) {
                  if (kept.contains(id) || doomed.contains(id)) continue;
                  if (!await cancel(id)) clean = false;
                }
              }
            } on FormatException {
              // An unreadable list names nothing we can cancel.
            }
            if (clean) await _preferences.remove(key);
          }
          for (final key in _preferences.getKeys().toList()) {
            if (key.startsWith(_statusPreferencePrefix) ||
                key.startsWith(_lowStockFiredPreferencePrefix) ||
                (key == reminderIdLedgerKey && ledgerClean) ||
                key == _legacyMigrationPreferenceKey ||
                key == _auditReportPreferenceKey) {
              await _preferences.remove(key);
            }
          }
          // Keep what still belongs to kept alarms; drop every reminder entry
          // whose alarm is gone. An entry whose cancel failed stays, so the
          // next pass sees the alarm is still there and ours.
          final remaining = {
            for (final entry in registry.entries)
              if (kept.contains(entry.key) || failedIds.contains(entry.key))
                entry.key: entry.value,
          };
          if (remaining.isEmpty) {
            await _preferences.remove(notificationProjectionRegistryKey);
          } else {
            await _persistRegistry(remaining);
          }
        }),
      );
    } on Object catch (error) {
      AppLogger.warning(
        'ProjectionReconciler',
        'Reminder reset could not clear: ${error.runtimeType}',
      );
      return const ReminderResetResult.failed(ReminderResetFailure.clear);
    }
    if (registryUnreadable) {
      return const ReminderResetResult.failed(ReminderResetFailure.registry);
    }

    ReconcileAllResult rebuilt;
    try {
      rebuilt = await (rebuild?.call() ?? reconcileAll(locale: locale));
    } on Object catch (error) {
      AppLogger.warning(
        'ProjectionReconciler',
        'Reminder rebuild failed: ${error.runtimeType}',
      );
      rebuilt = const ReconcileAllResult.failed();
    }
    try {
      await recheckStock?.call();
    } on Object catch (error) {
      AppLogger.warning(
        'ProjectionReconciler',
        'Stock recheck after reset failed: ${error.runtimeType}',
      );
    }
    if (!rebuilt.healthy) {
      // The alarms are cleared; whatever the runner's own retries manage, a
      // background task makes sure they come back even if the app is closed.
      try {
        await scheduleRetry?.call();
      } on Object catch (error) {
        AppLogger.warning(
          'ProjectionReconciler',
          'Reset retry task not queued: ${error.runtimeType}',
        );
      }
      return ReminderResetResult.failed(
        ReminderResetFailure.rebuild,
        restoring: rebuild != null,
      );
    }
    if (clearFailures > 0) {
      return const ReminderResetResult.failed(ReminderResetFailure.clear);
    }
    var scheduled = 0;
    try {
      scheduled = (await _platform.pendingRequests()).length;
    } on Object {
      // The count is informational.
    }
    return ReminderResetResult.success(removed: removed, scheduled: scheduled);
  }

  Future<AppLocalizations> _resolveLocalizations(Locale? requested) async {
    final code =
        requested?.languageCode ?? _preferences.getString('app_locale');
    final locale = code == null || code.isEmpty
        ? Locale(Platform.localeName.split('_').first)
        : Locale(code);
    try {
      return lookupAppLocalizations(locale);
    } on Object {
      // Notification scheduling must never silently stop on an unsupported OS
      // locale; this fallback is pinned by notification_service_test.dart.
      return AppLocalizationsEn();
    }
  }

  Future<ProjectionReconciliationReport> _persistReport(
    SessionIdentity identity, {
    required ProjectionReconciliationState state,
    required int desiredCount,
    required int scheduledCount,
    required int failureCount,
    required int availableCount,
    required int invalidCount,
  }) async {
    final report = _report(
      identity,
      state: state,
      desiredCount: desiredCount,
      scheduledCount: scheduledCount,
      failureCount: failureCount,
      availableCount: availableCount,
      invalidCount: invalidCount,
    );
    try {
      await _preferences.setString(
        statusKeyForUser(identity.$1),
        jsonEncode(report.toJson()),
      );
    } on Object catch (error) {
      AppLogger.warning(
        'ProjectionReconciler',
        'Reconciliation status persistence failed: ${error.runtimeType}',
      );
    }
    return report;
  }

  ProjectionReconciliationReport _report(
    SessionIdentity identity, {
    required ProjectionReconciliationState state,
    required int desiredCount,
    required int scheduledCount,
    required int failureCount,
    required int availableCount,
    required int invalidCount,
  }) => ProjectionReconciliationReport(
    userId: identity.$1,
    sessionGeneration: identity.$2,
    state: state,
    desiredCount: desiredCount,
    scheduledCount: scheduledCount,
    failedOperations: failureCount,
    availableCount: availableCount,
    invalidOccurrenceCount: invalidCount,
  );
}

class _CareSnapshot {
  const _CareSnapshot(
    this.activeProfileIds,
    this.occurrences,
    this.fingerprint,
    this.preferences,
  );
  final Set<String> activeProfileIds;
  final List<MedicationOccurrence> occurrences;
  final String fingerprint;
  final ReminderPreferences preferences;
}

class _PreparedReminders {
  const _PreparedReminders(
    this.localizations,
    this.activeProfileIds,
    this.occurrences,
    this.batch,
    this.fingerprint,
    this.preferences,
  );
  final AppLocalizations localizations;
  final Set<String> activeProfileIds;
  final List<MedicationOccurrence> occurrences;
  final ReminderProjectionBatch batch;
  final String fingerprint;
  final ReminderPreferences preferences;
}

class _ReconcileRequest {
  const _ReconcileRequest({
    required this.identity,
    required this.locale,
    this.projectionIdentity,
    this.activeActionsToRetain = const [],
    this.collector,
  });

  final SessionIdentity identity;
  final Locale? locale;
  final ProjectionIdentity? projectionIdentity;
  final List<_ActiveNotificationActionCandidate> activeActionsToRetain;
  final _AuditCollector? collector;
}

class _ActiveNotificationActionCandidate {
  const _ActiveNotificationActionCandidate({
    required this.notificationId,
    required this.occurrenceId,
    required this.projectionId,
    required this.kind,
    required this.stateVersion,
    required this.payload,
    required this.identity,
  });

  final int notificationId;
  final String occurrenceId;
  final String projectionId;
  final String kind;
  final int stateVersion;
  final String payload;
  final ProjectionIdentity identity;

  Map<String, Object?> get envelope => {
    'id': notificationId,
    'tag': null,
    'payload': payload,
    'actions': [
      {'id': 'taken', 'cancelNotification': true},
      {'id': 'snooze', 'cancelNotification': true},
      {'id': 'skip', 'cancelNotification': true},
    ],
  };
}

final projectionReconcilerProvider = Provider<ProjectionReconciler>((ref) {
  final preferences = ref.watch(sharedPreferencesProvider);
  final notificationService = NotificationService();
  return ProjectionReconciler(
    database: ref.watch(databaseProvider),
    preferences: preferences,
    generations: ref.watch(sessionGenerationRepositoryProvider),
    platform: notificationService,
    platformKind: ProjectionReconciler.currentPlatformKind,
    refreshActiveActions: notificationService.refreshActiveNotificationActions,
  );
});
