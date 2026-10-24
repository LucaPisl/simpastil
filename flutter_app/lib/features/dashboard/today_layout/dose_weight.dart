import 'package:flutter/material.dart';

import '../../../core/medication/care_day.dart';
import '../../../core/medication/care_recording.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import 'dose_morph.dart';
import 'entry_identity.dart';
import 'today_layout.dart';

// One weight rule for every Today layout, so a finished dose never outweighs
// the next one:
// - the next due slot (every unrecorded dose already due or, when none is,
//   the earliest one still ahead) carries the filled "Taken now";
// - a later dose carries a small outlined "Taken now", so recording one early
//   stays one tap;
// - a missed dose carries a small outlined "Taken now (late)" and a text Undo;
// - a taken or skipped dose plays its moment on the pressed button, then
//   shrinks to one quiet line with a text Undo.

const _radius = BorderRadius.all(Radius.circular(14));

/// The list layouts' "Taken now", filled for the next slot.
const listFilledShape = DoseButtonShape(
  height: 50,
  radius: 14,
  iconSize: 18,
  expand: true,
);

/// The list layouts' small outlined "Taken now", for a later or missed dose.
const listOutlinedShape = DoseButtonShape(
  height: 48,
  radius: 14,
  iconSize: 20,
  expand: false,
  padding: EdgeInsetsDirectional.fromSTEB(14, 8, 18, 8),
);

/// "Taken now" for a pending dose, "Taken now (late)" for a missed one,
/// weighted by [TodayLayoutData.isNextSlot]. Keyed `<prefix>-take-<id>`.
///
/// Once its receipt lands it plays the taken moment ([DoseActionButton]) and
/// is the dose's Undo (keyed `<prefix>-undo-<id>`) until the row collapses
/// into its quiet done line.
class DoseTakeButton extends StatelessWidget {
  const DoseTakeButton({
    super.key,
    required this.data,
    required this.entry,
    required this.prefix,
    this.onTake,
    this.onUndo,
    this.focusNode,
    this.hint,
  });

  final TodayLayoutData data;
  final CareDayEntry entry;
  final String prefix;

  /// The layout's own take path (for its focus handling); [data.onTake] when
  /// null.
  final void Function(CareDayEntry entry)? onTake;

  /// The layout's own undo path; [data.onUndo] when null.
  final void Function(CareDayEntry entry)? onUndo;
  final FocusNode? focusNode;

  /// Read after the label, for example "For Casey".
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final id = entry.occurrence.id;
    final row = data.rowOf(entry), head = data.headOf(entry);
    final missed = data.isMissed(entry);
    final done = data.isDone(entry);
    final enabled = done
        ? data.canUndo(entry)
        : missed
        ? data.canTakeLate(entry)
        : data.canTake(entry);
    final filled = data.isNextSlot(entry);
    return DoseActionButton(
      done: done,
      skipped: row.state == 'skipped',
      filled: filled,
      takeLabel: missed ? l.dose_takeLateNow : l.t08_takenNow,
      doneLabel: row.state == 'skipped' || head == null
          ? l.t08_skipped
          : l.dose_takenShort(recordedTimeLabel(context, head, row)),
      undoLabel: l.t08_undo,
      savingLabel: l.sc_saving,
      saving: data.isSaving(entry),
      onPressed: !enabled
          ? null
          : done
          ? () => (onUndo ?? data.onUndo)(entry)
          : () => (onTake ?? data.onTake)(entry),
      moment: data.momentOf(id),
      claim: data.claimMoment,
      takeShape: filled ? listFilledShape : listOutlinedShape,
      settle: DoseSettle.collapse,
      onSettled: () => data.onMorphSettled?.call(id),
      takeKey: ValueKey('$prefix-take-$id'),
      undoKey: ValueKey('$prefix-undo-$id'),
      focusNode: focusNode,
      hint: hint,
    );
  }
}

/// Undo as a quiet text button, never a full-width outline. Keyed
/// `<prefix>-undo-<id>`; hidden where the dose offers no Undo.
class DoseUndoButton extends StatelessWidget {
  const DoseUndoButton({
    super.key,
    required this.data,
    required this.entry,
    required this.prefix,
    this.onUndo,
    this.focusNode,
    this.hint,
  });

  final TodayLayoutData data;
  final CareDayEntry entry;
  final String prefix;
  final void Function(CareDayEntry entry)? onUndo;
  final FocusNode? focusNode;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    if (!data.offersUndo(entry)) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final saving = data.isSaving(entry);
    final button = TextButton.icon(
      key: ValueKey('$prefix-undo-${entry.occurrence.id}'),
      focusNode: focusNode,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      onPressed: data.canUndo(entry)
          ? () => (onUndo ?? data.onUndo)(entry)
          : null,
      icon: const Icon(Icons.undo, size: 18),
      label: Text(saving ? l.sc_saving : l.t08_undo),
    );
    return SavingPressable(
      saving: saving,
      radius: const BorderRadius.all(Radius.circular(12)),
      child: hint == null ? button : Semantics(hint: hint, child: button),
    );
  }
}

/// The action under a pending or missed dose: its take button and, for a
/// missed dose, a text Undo under it. A dose playing its taken moment keeps
/// its button alone. Null for a finished dose, whose Undo sits on its quiet
/// line instead.
Widget? doseActions(
  TodayLayoutData data,
  CareDayEntry entry, {
  required String prefix,
  void Function(CareDayEntry entry)? onTake,
  void Function(CareDayEntry entry)? onUndo,
  FocusNode? takeNode,
  FocusNode? undoNode,
  String? hint,
}) {
  final pending = data.isPending(entry), missed = data.isMissed(entry);
  final morphing = data.isMorphing(entry);
  if (!pending && !missed && !morphing) return null;
  final take = DoseTakeButton(
    data: data,
    entry: entry,
    prefix: prefix,
    onTake: onTake,
    onUndo: onUndo,
    focusNode: takeNode,
    hint: hint,
  );
  if (!missed || !data.offersUndo(entry)) return take;
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 4,
    children: [
      take,
      DoseUndoButton(
        data: data,
        entry: entry,
        prefix: prefix,
        onUndo: onUndo,
        focusNode: undoNode,
        hint: hint,
      ),
    ],
  );
}

/// The state in words, with the recorded time once there is one:
/// "Taken · 7:21 AM", "Missed", "Not recorded".
String doseStateText(
  BuildContext context,
  TodayLayoutData data,
  CareDayEntry entry,
) {
  final l = AppLocalizations.of(context);
  final row = data.rowOf(entry), head = data.headOf(entry);
  final state = data.stateLabel(l, entry);
  return data.isDone(entry) && head != null
      ? '$state · ${recordedTimeLabel(context, head, row)}'
      : state;
}

/// Whether a durable record needs the person to look at its sharing. Saved,
/// waiting, accepted and reviewed records stay quiet on a finished line.
bool sharingNeedsReview(CareSharingOutcome outcome) => switch (outcome) {
  CareSharingOutcome.localOnly ||
  CareSharingOutcome.pending ||
  CareSharingOutcome.acknowledged ||
  CareSharingOutcome.reconciled => false,
  _ => true,
};

/// A finished (taken or skipped) dose as one quiet line: [leading], the
/// medication name and its state with the time, and a text Undo at the end.
/// A sharing problem, if any, follows under it; nothing else does.
///
/// The name and state keep their own widgets (the state is keyed
/// `<prefix>-state-<id>`) and wrap onto a second line only when the text is
/// large or the name long. [onTap] opens the dose's details or expands the
/// row, as the layout does for its other doses; the tap target is keyed
/// `<prefix>-item-<id>` unless [itemKey] is false.
class QuietDoneLine extends StatelessWidget {
  const QuietDoneLine({
    super.key,
    required this.data,
    required this.entry,
    required this.prefix,
    required this.leading,
    required this.onTap,
    this.expanded,
    this.itemKey = true,
    this.time = false,
    this.person = false,
    this.onUndo,
    this.undoNode,
  });

  final TodayLayoutData data;
  final CareDayEntry entry;
  final String prefix;
  final Widget leading;
  final VoidCallback? onTap;

  /// Set where the line expands for details (Semantics only).
  final bool? expanded;
  final bool itemKey;

  /// Leads with the planned time, where the layout has no time column.
  final bool time;

  /// Adds "For Casey", where several people share the day.
  final bool person;
  final void Function(CareDayEntry entry)? onUndo;
  final FocusNode? undoNode;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final id = entry.occurrence.id;
    final row = data.rowOf(entry);
    final planned = plannedTimeLabel(context, row);
    final state = doseStateText(context, data, entry);
    final forPerson = l.t08_forPerson(entry.person.name);
    final sharing = data.sharingOf(entry);
    final nameStyle = text.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
      color: colors.onSurface,
    );
    final words = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 2,
      children: [
        Text(
          time
              ? '$planned · ${entry.snapshot.pillName}'
              : entry.snapshot.pillName,
          style: nameStyle,
        ),
        Text(
          state,
          key: ValueKey('$prefix-state-$id'),
          style: text.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: semantic.forState(row.state),
          ),
        ),
        if (person)
          Text(
            forPerson,
            style: text.labelMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
      ],
    );
    final tap = Semantics(
      button: onTap != null,
      expanded: expanded,
      liveRegion: true,
      label:
          '${l.lay_itemLabel(planned, entry.snapshot.pillName, data.stateLabel(l, entry))}'
          '${person ? ', $forPerson' : ''}',
      hint: expanded == null
          ? null
          : expanded!
          ? l.lay_hideDetails
          : l.lay_showDetails,
      excludeSemantics: true,
      child: InkWell(
        key: itemKey ? ValueKey('$prefix-item-$id') : null,
        borderRadius: _radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 6, 4, 6),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(child: words),
              ],
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              Expanded(child: tap),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * .45),
                child: DoseUndoButton(
                  data: data,
                  entry: entry,
                  prefix: prefix,
                  onUndo: onUndo,
                  focusNode: undoNode,
                  hint: person ? forPerson : null,
                ),
              ),
            ],
          ),
        ),
        if (sharingNeedsReview(sharing))
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, top: 2),
            child: DurableSaveFeedback(label: todaySharingLabel(l, sharing)),
          ),
      ],
    );
  }
}
