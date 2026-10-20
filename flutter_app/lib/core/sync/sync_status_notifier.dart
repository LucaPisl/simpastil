import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_error_classifier.dart';
import 'sync_models.dart';

// Re-export so consumers (AutoSyncService, tests) can import everything
// sync-status-related from this one file.
export 'sync_error_classifier.dart' show SyncFailedException;

enum SyncPhase { idle, syncing, failure }

class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.lastSuccessAt,
    this.lastError,
    this.failingSince,
    this.pendingCount = 0,
    this.counts = SyncOperationCounts.none,
    this.lastRun,
  });

  final SyncPhase phase;
  final DateTime? lastSuccessAt;
  final String? lastError;
  final DateTime? failingSince;
  final int pendingCount;

  /// Unsent changes by kind. [pendingCount] is everything not yet accepted
  /// (queued, retrying and stranded); [counts] says which of them need a
  /// person rather than time.
  final SyncOperationCounts counts;
  final SyncRunResult? lastRun;

  /// Changes that will never go out on their own (blocked, conflicting, or
  /// waiting behind one that is).
  bool get needsAttention => counts.needsAttention > 0;
}

/// Where a "needs attention" status leads: the "Fix sync problems" screen,
/// pushed under this route name.
const syncRecoveryRouteName = 'sync-recovery';

/// Single source of truth for sync attempts. AutoSyncService (and the
/// Settings manual sync) report outcomes here; the Settings sync section
/// watches it. Durable review state (issues and unsettled operations) is not
/// tracked here; it comes from SyncReviewRepository.
///
/// Timestamps are mirrored to SharedPreferences so results from the
/// WorkManager background isolate (which writes `last_sync_at` directly)
/// stay part of the same picture across app restarts.
class SyncStatusNotifier extends Notifier<SyncStatus> {
  static const _kLastSyncAt = 'last_sync_at';
  static const _kFailingSince = 'sync_failing_since';
  static const _kLastError = 'last_sync_error';
  static const _kOwner = 'sync_status_owner';

  bool _disposed = false;
  String? _adoptedUser;
  bool _sessionReset = false;

  @override
  SyncStatus build() {
    ref.onDispose(() => _disposed = true);
    unawaited(_restoreFromPrefs());
    return const SyncStatus();
  }

  Future<void> _restoreFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    // adoptSession discarded another account's outcome: never bring it back.
    if (_disposed || _sessionReset) return;
    final lastSyncAt = DateTime.tryParse(prefs.getString(_kLastSyncAt) ?? '');
    final failingSince = DateTime.tryParse(
      prefs.getString(_kFailingSince) ?? '',
    );

    // A background sync (WorkManager isolate) writes last_sync_at on success
    // but never clears the failure keys — a success newer than the failure
    // marker means the failure has healed.
    final healed =
        lastSyncAt != null &&
        failingSince != null &&
        lastSyncAt.isAfter(failingSince);
    if (healed) {
      await prefs.remove(_kFailingSince);
      await prefs.remove(_kLastError);
      // An account switch may have landed while the removes were pending.
      if (_disposed || _sessionReset) return;
    }

    // Only restore over a pristine state — a live sync outcome wins.
    if (state.phase != SyncPhase.idle || state.lastSuccessAt != null) return;
    final failing = failingSince != null && !healed;
    state = SyncStatus(
      phase: failing ? SyncPhase.failure : SyncPhase.idle,
      lastSuccessAt: lastSyncAt,
      failingSince: failing ? failingSince : null,
      lastError: failing
          ? normalizeSyncErrorCode(prefs.getString(_kLastError))
          : null,
      // pendingCount is not persisted; the first sync after launch recomputes it.
      pendingCount: 0,
    );
  }

  /// Ties the displayed outcome to the signed-in account. The first sync of a
  /// session calls this: when the stored outcome belongs to a different
  /// account, its "last synced" time and failure marker are discarded so a
  /// new sign-in never shows another session's "Failing since ...". Status
  /// written before the owner was recorded (an upgrade) is kept and claimed.
  Future<void> adoptSession(String userId) async {
    if (_adoptedUser == userId) return;
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    final owner = prefs.getString(_kOwner);
    _adoptedUser = userId;
    if (owner != null && owner != userId) {
      _sessionReset = true;
      state = SyncStatus(
        phase: state.phase == SyncPhase.syncing
            ? SyncPhase.syncing
            : SyncPhase.idle,
      );
      await prefs.remove(_kLastSyncAt);
      await prefs.remove(_kFailingSince);
      await prefs.remove(_kLastError);
    }
    if (owner != userId) await prefs.setString(_kOwner, userId);
    // Same account (or an unowned upgrade): show its stored outcome now,
    // before the caller flips the phase to syncing, which would otherwise
    // block the restore and hide the stored "last synced" until the run ends.
    if (!_sessionReset) await _restoreFromPrefs();
  }

  /// Refreshes only the unsent-change tally (after a recovery action changed
  /// the outbox), leaving the outcome of the last sync untouched.
  void updateCounts({
    required int pendingCount,
    required SyncOperationCounts counts,
  }) {
    state = SyncStatus(
      phase: state.phase,
      lastSuccessAt: state.lastSuccessAt,
      lastError: state.lastError,
      failingSince: state.failingSince,
      pendingCount: pendingCount,
      counts: counts,
      lastRun: state.lastRun,
    );
  }

  void markSyncing() {
    state = SyncStatus(
      phase: SyncPhase.syncing,
      lastSuccessAt: state.lastSuccessAt,
      lastError: state.lastError,
      failingSince: state.failingSince,
      pendingCount: state.pendingCount,
      counts: state.counts,
      lastRun: state.lastRun,
    );
  }

  /// Rolls a syncing phase back to its pre-attempt appearance without
  /// recording an outcome — used when an attempt ends in an auth failure,
  /// which the AuthInterceptor logout gate owns.
  void revertSyncing() {
    if (state.phase != SyncPhase.syncing) return;
    state = SyncStatus(
      phase: state.failingSince != null ? SyncPhase.failure : SyncPhase.idle,
      lastSuccessAt: state.lastSuccessAt,
      lastError: state.lastError,
      failingSince: state.failingSince,
      pendingCount: state.pendingCount,
      counts: state.counts,
      lastRun: state.lastRun,
    );
  }

  Future<void> markSuccess({
    required int pendingCount,
    SyncOperationCounts counts = SyncOperationCounts.none,
    SyncRunResult? lastRun,
  }) async {
    final now = DateTime.now();
    state = SyncStatus(
      phase: SyncPhase.idle,
      lastSuccessAt: now,
      pendingCount: pendingCount,
      counts: counts,
      lastRun: lastRun,
    );
    final prefs = await SharedPreferences.getInstance();
    // Persist even if a newer attempt already flipped the phase back to
    // syncing: a success must always clear the failure marker, or the next
    // launch restores a "Failing since ..." the user has already recovered from.
    if (_disposed) return;
    await prefs.setString(_kLastSyncAt, now.toIso8601String());
    await prefs.remove(_kFailingSince);
    await prefs.remove(_kLastError);
  }

  Future<void> markFailure(
    Object error, {
    required int pendingCount,
    SyncOperationCounts? counts,
    SyncRunResult? lastRun,
  }) async {
    final blockedByLocalAccess =
        lastRun?.stages.any(
          (stage) =>
              stage.outcome.safeErrorCode ==
              'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
        ) ??
        false;
    final message = blockedByLocalAccess
        ? 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE'
        : classifySyncError(error);
    final failingSince = state.failingSince ?? DateTime.now();
    state = SyncStatus(
      phase: SyncPhase.failure,
      lastSuccessAt: state.lastSuccessAt,
      lastError: message,
      failingSince: failingSince,
      pendingCount: pendingCount,
      counts: counts ?? state.counts,
      lastRun: lastRun ?? state.lastRun,
    );
    final prefs = await SharedPreferences.getInstance();
    if (_disposed || state.phase != SyncPhase.failure) return;
    await prefs.setString(_kFailingSince, failingSince.toIso8601String());
    await prefs.setString(_kLastError, message);
  }
}

final syncStatusProvider = NotifierProvider<SyncStatusNotifier, SyncStatus>(
  SyncStatusNotifier.new,
);
