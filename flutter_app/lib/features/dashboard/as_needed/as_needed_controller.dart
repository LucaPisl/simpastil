import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart' show Schedule;
import '../../../core/errors/app_error.dart' show Ok;
import '../../../core/medication/care_provider.dart';
import '../../../core/medication/care_recording.dart';
import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/prn_limits.dart';
import '../../../core/medication/medication_repository.dart'
    show MedicationCommandBlocked;
import '../../../core/medication/reviewed_stock.dart' show CareStockOutcome;
import '../../../core/medication/routine_definition.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../pills/schedule_provider.dart';
import '../care_record_form.dart' show careServiceIsCurrent, sameCareContext;
import 'as_needed_option.dart';
import 'as_needed_summary.dart';

/// How long Undo stays on a card after a dose is recorded.
const asNeededUndoWindow = Duration(seconds: 6);

enum AsNeededPhase { idle, committing, taken, undoing, error }

/// What one as-needed card is doing right now.
@immutable
class AsNeededRun {
  const AsNeededRun({
    this.phase = AsNeededPhase.idle,
    this.visible = true,
    this.receipt,
    this.takenAt,
    this.token = 0,
    this.undoStartedAt,
    this.saveFailed = false,
  });

  final AsNeededPhase phase;

  /// False while a dose recorded from another page is not yet shown, so the
  /// card can play its success moment once the person is back on Today.
  final bool visible;
  final CareRecordingReceipt? receipt;
  final DateTime? takenAt;

  /// Changes with every recorded dose, so a card restarts its moment.
  final int token;
  final DateTime? undoStartedAt;
  final bool saveFailed;

  bool get busy =>
      phase == AsNeededPhase.committing || phase == AsNeededPhase.undoing;
  bool get showsTaken => phase == AsNeededPhase.taken && visible;
}

/// Records and undoes as-needed doses for the section, for every path to it:
/// the card's hold, the details sheet and the dose editor.
///
/// It owns no storage. Each dose still goes through [CareRecordingService]:
/// the session and generation are rechecked before publishing, a commit is
/// idempotent, and Undo commits the prepared reversal of the exact receipt.
class AsNeededController extends ChangeNotifier {
  AsNeededController({
    required this.ref,
    required this.localDate,
    required this.canFeel,
    required this.onUndoStockUnchanged,
    this.confirmOverLimit,
  });

  /// Asked before a dose that would pass a limit the person set is recorded.
  /// Resolves true to record anyway. Without it nothing is asked (the widget
  /// and notification paths never reach this controller at all).
  final Future<bool> Function(AsNeededOption option, PrnLimitState state)?
  confirmOverLimit;

  /// True when the last [record] returned false because the person chose not
  /// to record a dose over a limit, so the caller shows no error for it.
  bool declinedOverLimit = false;

  /// True when the last [record] did nothing because another dose of the same
  /// medication was already being recorded or asked about (the busy guard).
  /// Nothing failed: a caller must not show a save error for it.
  bool ignoredWhileBusy = false;

  /// True when the last [record] did nothing because the medication must be
  /// reviewed in Settings first. Nothing was saved, and a caller says why.
  bool waitsForReview = false;

  final WidgetRef ref;
  final String Function() localDate;
  final bool Function() canFeel;

  /// Called when an undo was saved but the phone's stock count stayed as it
  /// was, so the person can correct it by hand.
  final void Function() onUndoStockUnchanged;

  final Map<String, AsNeededRun> _runs = {};
  final Map<String, Timer> _timers = {};
  final Map<String, ({CareRecordingService service, PreparedCareIntent intent})>
  _pending = {};
  final Set<String> _asking = {};
  int _serial = 0;
  bool _disposed = false;

  AsNeededRun runOf(String pillId) => _runs[pillId] ?? const AsNeededRun();

  bool get viewingToday => localDate() == routineDateKey(DateTime.now());

  /// "Now" when viewing today; a past day records with the time not known.
  DateTime? holdTime() => viewingToday ? DateTime.now() : null;

  void _set(String pillId, AsNeededRun run) {
    if (_disposed) return;
    _runs[pillId] = run;
    notifyListeners();
  }

  /// Records one dose. Returns true once it is durably saved.
  Future<bool> record(
    AsNeededOption option, {
    required MedicationAmount amount,
    required DateTime? at,
    String? note,
    bool reveal = true,
    bool fresh = false,
  }) async {
    final pillId = option.pillId;
    final before = runOf(pillId);
    // The over-limit dialog is open for this medication: a second hold or tap
    // must not record another dose behind it.
    declinedOverLimit = false;
    ignoredWhileBusy = false;
    waitsForReview = false;
    if (option.needsReview) {
      waitsForReview = true;
      return false;
    }
    if (before.busy || _asking.contains(pillId)) {
      ignoredWhileBusy = true;
      return false;
    }
    final ask = confirmOverLimit;
    // A dose on a past day with no known time has no moment to judge the
    // limits at ("now" would warn about, or miss, a dose from days ago), so
    // the check is skipped. Otherwise a dose is judged where it falls.
    final judgeable = at != null || viewingToday;
    if (ask != null && judgeable && _pending[pillId] == null) {
      final state = _limitStateFor(pillId, at ?? DateTime.now());
      if (state != null && state.overLimit) {
        _asking.add(pillId);
        final bool confirmed;
        try {
          confirmed = await ask(option, state);
        } finally {
          _asking.remove(pillId);
        }
        if (!confirmed) {
          declinedOverLimit = true;
          return false;
        }
      }
      if (_disposed) return false;
    }
    _timers.remove(pillId)?.cancel();
    if (fresh) _pending.remove(pillId);
    _set(pillId, const AsNeededRun(phase: AsNeededPhase.committing));
    try {
      var prepared = _pending[pillId];
      if (prepared == null) {
        final captured = ref.read(workspaceContextProvider).asData?.value;
        if (captured == null) {
          _set(pillId, const AsNeededRun());
          return false;
        }
        final service = await ref.read(careRecordingServiceProvider.future);
        if (_disposed ||
            !sameCareContext(captured, service.context) ||
            !careServiceIsCurrent(ref, service)) {
          _set(pillId, const AsNeededRun());
          return false;
        }
        final intent = await option.prepare(
          service,
          localDate: localDate(),
          amount: amount,
          at: at,
          note: note,
          createSentinel: () => _createSentinel(pillId),
        );
        prepared = (service: service, intent: intent);
        _pending[pillId] = prepared;
      }
      // A retried intent skipped the checks above, and preparing awaited.
      final current = ref.read(workspaceContextProvider).asData?.value;
      if (_disposed ||
          current == null ||
          !sameCareContext(current, prepared.service.context) ||
          !careServiceIsCurrent(ref, prepared.service)) {
        _pending.remove(pillId);
        _set(pillId, const AsNeededRun());
        return false;
      }
      final receipt = await prepared.service.commit(prepared.intent);
      _pending.remove(pillId);
      if (_disposed) return true;
      await prepared.service.access.requireCurrent(prepared.service.context);
      if (_disposed) return true;
      _set(
        pillId,
        AsNeededRun(
          phase: AsNeededPhase.taken,
          visible: reveal,
          receipt: receipt,
          takenAt: at,
          token: ++_serial,
          undoStartedAt: DateTime.now(),
        ),
      );
      if (reveal) _startUndoTimer(pillId);
      if (canFeel()) HapticFeedback.mediumImpact();
      return true;
    } on AsNeededSaveFailed {
      _set(
        pillId,
        const AsNeededRun(phase: AsNeededPhase.error, saveFailed: true),
      );
      return false;
    } on Object catch (error) {
      // Cause only: the fixed block code or the exception type, never a
      // message or any medication data.
      AppLogger.warning(
        'AsNeeded',
        'take failed: '
            '${error is MedicationCommandBlocked ? error.code : error.runtimeType}',
      );
      // A refused command will be refused again: the next try starts afresh.
      if (error is MedicationCommandBlocked) _pending.remove(pillId);
      _set(pillId, const AsNeededRun(phase: AsNeededPhase.error));
      return false;
    }
  }

  PrnLimitState? _limitStateFor(String pillId, DateTime at) {
    final summary = ref.read(asNeededSummariesProvider).value?[pillId];
    if (summary == null || !summary.hasLimit) return null;
    return summary.limitAt(at);
  }

  Future<Schedule?> _createSentinel(String pillId) async {
    final created = await ref
        .read(scheduleRepositoryProvider)
        .create(pillId: pillId, hour: 0, minute: 0, frequency: 'prn');
    return created is Ok<Schedule> ? created.value : null;
  }

  /// Shows a dose recorded elsewhere (the editor) on its card, after [delay].
  void reveal(String pillId, {Duration delay = Duration.zero}) {
    void show() {
      final run = runOf(pillId);
      if (_disposed || run.phase != AsNeededPhase.taken || run.visible) return;
      _set(
        pillId,
        AsNeededRun(
          phase: AsNeededPhase.taken,
          receipt: run.receipt,
          takenAt: run.takenAt,
          token: run.token,
          undoStartedAt: DateTime.now(),
        ),
      );
      _startUndoTimer(pillId);
      if (canFeel()) HapticFeedback.mediumImpact();
    }

    if (delay == Duration.zero) {
      show();
    } else {
      _timers[pillId]?.cancel();
      _timers[pillId] = Timer(delay, show);
    }
  }

  void _startUndoTimer(String pillId) {
    _timers[pillId]?.cancel();
    _timers[pillId] = Timer(asNeededUndoWindow, () {
      _timers.remove(pillId);
      final run = runOf(pillId);
      if (run.phase == AsNeededPhase.taken) {
        _set(pillId, const AsNeededRun());
      }
    });
  }

  /// Commits the prepared reversal of the dose the card just recorded.
  Future<void> undo(String pillId) async {
    final run = runOf(pillId);
    final receipt = run.receipt;
    if (run.phase != AsNeededPhase.taken || receipt == null) return;
    _timers.remove(pillId)?.cancel();
    _set(
      pillId,
      AsNeededRun(
        phase: AsNeededPhase.undoing,
        receipt: receipt,
        takenAt: run.takenAt,
        token: run.token,
      ),
    );
    try {
      final captured = ref.read(workspaceContextProvider).asData?.value;
      final service = await ref.read(careRecordingServiceProvider.future);
      if (_disposed ||
          captured == null ||
          !sameCareContext(captured, service.context) ||
          !careServiceIsCurrent(ref, service)) {
        _set(pillId, const AsNeededRun());
        return;
      }
      final intent = await service.prepareUndo(receipt);
      final undone = await service.commit(intent);
      if (_disposed) return;
      await service.access.requireCurrent(service.context);
      if (_disposed) return;
      _set(pillId, const AsNeededRun());
      if (undone.stock == CareStockOutcome.unchanged) {
        onUndoStockUnchanged();
      }
      if (canFeel()) HapticFeedback.lightImpact();
    } on Object catch (error) {
      AppLogger.warning(
        'AsNeeded',
        'undo failed: '
            '${error is MedicationCommandBlocked ? error.code : error.runtimeType}',
      );
      _set(pillId, const AsNeededRun(phase: AsNeededPhase.error));
    }
  }

  /// Clears a card's error so the person sees the plain card again.
  void clearError(String pillId) {
    if (runOf(pillId).phase == AsNeededPhase.error) {
      _set(pillId, const AsNeededRun());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}
