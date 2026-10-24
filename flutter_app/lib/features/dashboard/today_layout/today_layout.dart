import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/db/database.dart'
    show MedicationOccurrence, OccurrenceEvent;
import '../../../core/medication/care_day.dart';
import '../../../core/medication/care_recording.dart';
import '../care_record_form.dart' show careAmountLabel;
import '../../../core/medication/late_dose.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../today_side/stock_overview.dart' show StockRow;
import 'receipt_moment.dart';

export 'receipt_moment.dart';

/// Whether the head event of a recorded dose can be undone from the app. The
/// event backfilled for a dose recorded before ledger activation
/// (`legacy_handoff`) cannot, and neither can an Undo itself.
bool headOffersUndo(OccurrenceEvent? head) =>
    head != null && head.action != 'undo' && head.origin != 'legacy_handoff';

/// Builds one Today layout from the day and its actions.
typedef TodayLayoutBuilder =
    Widget Function(BuildContext context, TodayLayoutData data);

/// Everything an alternative Today layout may read or do.
///
/// One value is built by the deck State (`FocusDeck` in `focus_deck.dart`)
/// on every build. That State lives under the Today identity key (workspace,
/// access epoch, session generation, network epoch, day, person), so every
/// callback here is bound to exactly one care context and disappears with
/// it. Layouts must not cache these callbacks beyond their own build, and
/// must not record by any other path: [onTake] and [onUndo] are the deck's
/// own guarded `_record`, which re-checks the care context, holds the
/// prepared intent for a retry, waits for the durable commit and only then
/// stores the receipt, plays the moment and the receipt haptic.
///
/// The sky header, person selector, date controls and the as-needed section
/// stay shared above and below the layout; a layout renders only the
/// scheduled doses of [day].
@immutable
class TodayLayoutData {
  const TodayLayoutData({
    required this.day,
    required this.focusedId,
    required this.busyId,
    required this.error,
    required this.rowOf,
    required this.headOf,
    required this.sharingOf,
    required this.momentOf,
    required this.settleToken,
    required this.claimMoment,
    required this.onMomentDone,
    required this.travelTimeOf,
    required this.isToday,
    required this.now,
    required this.onTake,
    required this.onUndo,
    required this.onFocus,
    required this.onOpenDetails,
    this.onSelectDoses,
    this.asNeeded = const [],
    this.onOpenOverview,
    this.lowStock = const [],
    this.onAddStock,
    this.onDismissLowStock,
    this.morphs = const {},
    this.onMorphSettled,
  });

  /// Scheduled doses only (pending as-needed sentinels are removed), in
  /// planned order.
  final CareDay day;

  /// Occurrence the user last focused here or on the sky; shared by every
  /// layout so switching layouts keeps the place.
  final String? focusedId;

  /// Occurrence whose take or undo is being saved; all actions are disabled
  /// while it is set.
  final String? busyId;

  /// The last record error in words, or null.
  final String? error;

  /// The occurrence as this State knows it: a stored receipt wins over an
  /// older provider row, so a row never flickers back after a take.
  final MedicationOccurrence Function(CareDayEntry entry) rowOf;

  /// The latest event for [rowOf], or null when nothing was recorded.
  final OccurrenceEvent? Function(CareDayEntry entry) headOf;
  final CareSharingOutcome Function(CareDayEntry entry) sharingOf;

  /// The receipt moment to play on this occurrence's [ReceiptCapsule], if any.
  final ReceiptMoment? Function(String occurrenceId) momentOf;

  /// Receipt token whose take brought the day to zero (for [SettleHalo]).
  final String? settleToken;

  /// Pass to [ReceiptCapsule.claim] / [SettleHalo.claim].
  final bool Function(String token) claimMoment;

  /// Pass to [ReceiptCapsule.onDone] / [SettleHalo.onDone].
  final ValueChanged<String> onMomentDone;

  /// "Saved for 09:00 in Bucharest · 08:00 here" when zones differ, else null.
  final String? Function(MedicationOccurrence row) travelTimeOf;

  /// Whether [day] is the device's current day.
  final bool isToday;

  /// The app clock when this value was built; the deck rebuilds it every
  /// minute, so the next slot moves on as doses fall due.
  final DateTime now;

  /// The deck's guarded record path. Callers only check [canTake]/[canUndo].
  final void Function(CareDayEntry entry) onTake;
  final void Function(CareDayEntry entry) onUndo;

  /// Marks an occurrence as the shared place (no scroll in other layouts).
  final ValueChanged<String> onFocus;

  /// Opens `/doses/<id>`.
  final void Function(CareDayEntry entry) onOpenDetails;

  /// Opens the reviewed multi-dose selection, or null when nothing can be
  /// selected.
  final VoidCallback? onSelectDoses;

  /// As-needed doses already recorded on [day], kept apart from the scheduled
  /// [day] entries. Read them through `asNeededRecords` (as_needed_entry.dart),
  /// which also picks up any as-needed row that sits in [day] itself.
  final List<CareDayEntry> asNeeded;

  /// Opens the Day overview sheet (and focuses the dose picked there), or
  /// null where the layout has none.
  final VoidCallback? onOpenOverview;

  /// Medication that runs low and was not put off with "Later" today. Set
  /// only where the notice shows (the phone's Today, on the current day);
  /// empty otherwise, so a layout draws nothing.
  final List<StockRow> lowStock;

  /// Opens the existing stock editor for [lowStock]'s row, or null where
  /// this workspace has none (then the notice states the fact without an
  /// "Add stock" link).
  final void Function(StockRow row)? onAddStock;

  /// Hides a low-stock notice until tomorrow on this device ("Later"), or
  /// null where the layout offers no such choice.
  final void Function(StockRow row)? onDismissLowStock;

  /// Doses whose main button is playing its taken (or skipped) moment, each
  /// with the receipt key it had before: until the moment settles, the row
  /// keeps that key and its open body, then collapses into its done row.
  final Map<String, String> morphs;

  /// Called by a dose's main button once its moment has played.
  final ValueChanged<String>? onMorphSettled;

  bool get busy => busyId != null;
  List<CareDayEntry> get entries => day.entries;
  bool isSaving(CareDayEntry entry) => busyId == entry.occurrence.id;
  bool isPending(CareDayEntry entry) => rowOf(entry).state == 'pending';

  /// A dose the app recorded as missed. It is a recorded outcome, but the
  /// person can still take it late, skip it, or undo the miss.
  bool isMissed(CareDayEntry entry) => rowOf(entry).state == 'missed';

  /// Taken after it was recorded missed.
  bool isTakenLateEntry(CareDayEntry entry) =>
      isTakenLate(rowOf(entry).state, headOf(entry));

  /// The state of [entry] in words, "Taken (late)" included.
  String stateLabel(AppLocalizations l, CareDayEntry entry) =>
      careStateLabel(l, rowOf(entry).state, late: isTakenLateEntry(entry));

  bool canTake(CareDayEntry entry) =>
      !busy && entry.canRecord && isPending(entry);

  /// Taking a missed dose late goes through the same guarded take as any dose;
  /// the repository records it as a correction of the miss.
  bool canTakeLate(CareDayEntry entry) =>
      !busy && entry.canRecord && isMissed(entry);

  /// Whether [entry] shows Undo at all. A dose recorded before the ledger was
  /// activated can be changed but not undone: its stock effect is part of the
  /// handoff, not of its event, so the control is hidden rather than disabled.
  bool offersUndo(CareDayEntry entry) => headOffersUndo(headOf(entry));

  bool canUndo(CareDayEntry entry) =>
      !busy && !isPending(entry) && offersUndo(entry);

  /// Taken or skipped: a finished dose that shrinks to one quiet line. A
  /// missed dose is not finished; it can still be taken late.
  bool isDone(CareDayEntry entry) {
    final state = rowOf(entry).state;
    return state == 'taken' || state == 'skipped';
  }

  /// Whether [entry]'s main button is still playing its moment.
  bool isMorphing(CareDayEntry entry) =>
      morphs.containsKey(entry.occurrence.id);

  /// A finished dose whose moment has played: the row shows its quiet done
  /// line.
  bool showsDone(CareDayEntry entry) => isDone(entry) && !isMorphing(entry);

  /// The receipt key a row swaps on; held at the one before the take while
  /// the moment plays, so the button morphs in place.
  String swapKeyOf(CareDayEntry entry) {
    final row = rowOf(entry);
    return morphs[entry.occurrence.id] ??
        ReceiptSwap.of(row.state, row.stateVersion);
  }

  /// Whether [entry] is in the next due slot and so carries the filled
  /// "Taken now"; see [inNextDueSlot].
  bool isNextSlot(CareDayEntry entry) =>
      inNextDueSlot(entry, day.entries, rowOf, now);

  /// Expected doses still unrecorded, following stored receipts.
  int get remaining => day.entries
      .where((e) => e.occurrence.expected && rowOf(e).state == 'pending')
      .length;

  /// Expected doses recorded as missed, following stored receipts.
  int get missedCount => day.entries
      .where((e) => e.occurrence.expected && rowOf(e).state == 'missed')
      .length;

  bool get hasExpected => day.entries.any((e) => e.occurrence.expected);

  /// Nothing is left to record and nothing was missed: a day with a missed
  /// dose is never called "all recorded".
  bool get allRecorded =>
      hasExpected && remaining == 0 && missedCount == 0 && isToday;

  /// Whether to say "All planned entries have a recorded outcome": only on a
  /// recorded day where nothing was missed.
  bool get showsKnownOutcomes =>
      day.state == CareDayState.recorded && hasExpected && missedCount == 0;

  /// The count line every layout shows, in words.
  String countLabel(AppLocalizations l) => !hasExpected
      ? l.t10_recordHistory
      : allRecorded
      ? l.sc_allRecorded
      : remaining == 0 && missedCount > 0
      ? l.dose_missedCount(missedCount)
      : l.t08_remaining(remaining);
}

/// Whether [entry] belongs to the next due slot of [entries] and so carries
/// the filled "Taken now". While any unrecorded dose is already due, those
/// doses are the next slot (overdue counts as next); otherwise it is every
/// dose at the earliest planned moment still ahead of [now]. Later doses
/// carry a small outlined "Taken now" instead. [rowOf] reads each dose's
/// latest stored state.
bool inNextDueSlot(
  CareDayEntry entry,
  Iterable<CareDayEntry> entries,
  MedicationOccurrence Function(CareDayEntry entry) rowOf,
  DateTime now,
) {
  final row = rowOf(entry);
  if (row.state != 'pending') return false;
  final at = row.plannedAt;
  if (at == null) return false;
  if (!at.isAfter(now)) return true;
  DateTime? next;
  for (final other in entries) {
    final r = rowOf(other);
    final t = r.plannedAt;
    if (r.state != 'pending' || t == null) continue;
    // Something is already due: that is the next slot, not this one.
    if (!t.isAfter(now)) return false;
    if (next == null || t.isBefore(next)) next = t;
  }
  return next != null && at.isAtSameMomentAs(next);
}

/// The state of a dose in words; colour is never the only carrier. [late]
/// marks a taken dose that was recorded missed first.
String careStateLabel(AppLocalizations l, String state, {bool late = false}) =>
    switch (state) {
      'taken' => late ? l.dose_takenLate : l.t08_taken,
      'skipped' => l.t08_skipped,
      'missed' => l.dashboard_statusMissed,
      _ => l.t08_unrecorded,
    };

/// Where a durable record stands, in words.
String todaySharingLabel(AppLocalizations l, CareSharingOutcome outcome) =>
    switch (outcome) {
      CareSharingOutcome.localOnly => l.t08_saved,
      CareSharingOutcome.pending => l.t08_pendingShare,
      CareSharingOutcome.acknowledged => l.t08_shared,
      CareSharingOutcome.reconciled => l.t10_sharingReconciled,
      _ => l.t08_reviewShare,
    };

/// A planned local time on the phone's clock ("9:00 AM" or "09:00"), or
/// "As needed".
String plannedTimeLabel(BuildContext context, MedicationOccurrence row) {
  final time = row.plannedLocalTime;
  return time == null
      ? AppLocalizations.of(context).t08_asNeeded
      : clockText(context, time);
}

/// When a recorded dose actually happened, in the routine's zone, or
/// "Time not known". Unknown actual times are never shown as known.
String recordedTimeLabel(
  BuildContext context,
  OccurrenceEvent head,
  MedicationOccurrence row,
) {
  if (!head.actualTimeKnown || head.actualAt == null) {
    return AppLocalizations.of(context).t08_unknownTime;
  }
  return clockAt(
    context,
    tz.TZDateTime.from(head.actualAt!, tz.getLocation(row.timeZone)),
  );
}

/// The amount a dose card shows: "1/2 tablets", or "Amount not specified"
/// when none is known, the same on every layout and in the focus deck. A
/// recorded dose shows the amount it was recorded with.
String plannedAmountLabel(AppLocalizations l, CareDayEntry entry) =>
    entry.plannedAmount.isUnknown
    ? l.t08_amountNotSpecified
    : careAmountLabel(l, entry.plannedAmount);
