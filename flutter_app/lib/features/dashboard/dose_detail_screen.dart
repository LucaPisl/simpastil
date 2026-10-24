import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/inventory/exact_stock.dart';
import '../../core/inventory/stock_format.dart';
import '../../core/medication/care_provider.dart';
import '../../core/medication/care_recording.dart';
import '../../core/medication/late_dose.dart';
import '../../core/medication/medication_repository.dart'
    show MedicationCommandBlocked;
import '../../core/medication/occurrence_detail_provider.dart';
import '../../core/medication/occurrence_detail_repository.dart';
import '../../core/medication/routine_definition.dart';
import '../../core/workspace/workspace_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/layouts/window_size.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/care_state.dart';
import '../pills/presentation/medication_detail_sections.dart'
    show hasOriginalDosageText;
import '../pills/presentation/medication_identity.dart';
import '../pills/presentation/medication_photo_card.dart';
import '../schedules/presentation/day_part.dart';
import 'care_record_form.dart';
import 'care_record_launch.dart';
import 'dose_story.dart';
import 'previous_slots.dart';
import '../../shared/format/clock.dart';

/// The full-page Dose details route (`/doses/:occurrenceId`), used on phones
/// and wherever there is no room for the side panel.
class DoseDetailScreen extends StatelessWidget {
  const DoseDetailScreen({super.key, required this.occurrenceId});
  final String occurrenceId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(AppLocalizations.of(context).t10_details)),
    body: SafeArea(
      top: false,
      child: DoseDetailView(occurrenceId: occurrenceId),
    ),
  );
}

/// Dose details beside Today on a wide window: the same body as the page,
/// under a header with a close control. It replaces the right-hand column
/// while it is open.
class DoseDetailPanel extends StatelessWidget {
  const DoseDetailPanel({
    super.key,
    required this.occurrenceId,
    required this.onClose,
  });
  final String occurrenceId;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l.t10_details,
      child: Material(
        key: const ValueKey('dose-details-panel'),
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: .5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        l.t10_details,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('dose-details-close'),
                    tooltip: l.tt_detailsClose,
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: DoseDetailView(
                key: ValueKey(occurrenceId),
                occurrenceId: occurrenceId,
                embedded: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The body of Dose details: who and what, the amount, the state, what stock
/// is left after taking it, the direct record actions, the previous
/// occurrences of the same slot, and the recorded story and history.
///
/// Every write goes through the same care recording service as Today: Taken
/// now commits an immediate record, Taken at another time and Skipped open
/// the review form, Correct and Undo are unchanged.
class DoseDetailView extends ConsumerStatefulWidget {
  const DoseDetailView({
    super.key,
    required this.occurrenceId,
    this.embedded = false,
  });
  final String occurrenceId;

  /// True inside the side panel, which supplies its own header and surface.
  final bool embedded;
  @override
  ConsumerState<DoseDetailView> createState() => _DoseDetailViewState();
}

class _DoseDetailViewState extends ConsumerState<DoseDetailView> {
  bool _busy = false;
  String? _error;
  ({CareRecordingService service, PreparedCareIntent intent})? _undo;
  ({CareRecordingService service, PreparedCareIntent intent})? _take;

  Future<CareRecordingService?> _capture() async {
    final current = ref.read(workspaceContextProvider);
    if (current.isLoading || current.hasError || current.asData == null) {
      return null;
    }
    final service = await ref.read(careRecordingServiceProvider.future);
    if (!mounted ||
        !sameCareContext(current.requireValue, service.context) ||
        !careServiceIsCurrent(ref, service)) {
      return null;
    }
    return service;
  }

  Future<void> _record(OccurrenceCareDetail detail, {bool skip = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = await _capture();
      if (service == null || !mounted) return;
      final l = AppLocalizations.of(context);
      await openCareRecordForm(
        context,
        service: service,
        personId: detail.personId!,
        personName: detail.personName ?? l.t10_unknownPerson,
        medicationName: detail.medicationName ?? l.t10_unknownMedication,
        occurrenceId: detail.occurrence.id,
        localDate: detail.occurrence.plannedLocalDate,
        state: detail.occurrence.state,
        stateVersion: detail.occurrence.stateVersion,
        amount: detail.occurrence.state == 'missed'
            ? detail.plannedAmount
            : detail.head?.amount ?? detail.plannedAmount,
        initialActualAt: detail.head?.event.actualTimeKnown == true
            ? detail.head?.event.actualAt
            : null,
        initialNote: detail.head?.event.note,
        skip: skip,
      );
    } on Object {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).t08_recordError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Records the dose as taken now, the same immediate record the Taken now
  /// button on Today makes. A failed commit keeps its prepared intent so the
  /// retry replays the same command instead of recording twice.
  Future<void> _takeNow(OccurrenceCareDetail detail) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var pending = _take;
      if (pending == null) {
        final service = await _capture();
        if (service == null || !mounted) return;
        final intent = await service.prepareTakenNow(
          personId: detail.personId!,
          occurrenceId: detail.occurrence.id,
          expectedStateVersion: detail.occurrence.stateVersion,
          amount: detail.plannedAmount,
        );
        pending = (service: service, intent: intent);
        _take = pending;
      }
      if (!mounted || !careServiceIsCurrent(ref, pending.service)) {
        _take = null;
        return;
      }
      await pending.service.commit(pending.intent);
      if (mounted) setState(() => _take = null);
    } on Object catch (error) {
      // A refusal (the dose moved on since it was prepared) is final for that
      // command: replaying it would be refused again, so prepare a new one
      // from the refreshed dose on the next try. Any other failure keeps the
      // intent, so the retry is the same idempotent command.
      if (error is MedicationCommandBlocked) _take = null;
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).t08_recordError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw(OccurrenceCareDetail detail) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var pending = _undo;
      if (pending == null) {
        final service = await _capture();
        if (service == null || !mounted) return;
        final intent = await service.prepareUndoForEntry(
          personId: detail.personId!,
          occurrenceId: detail.occurrence.id,
          expectedStateVersion: detail.occurrence.stateVersion,
          headEventId: detail.head!.event.id,
        );
        pending = (service: service, intent: intent);
        _undo = pending;
      }
      await pending.service.commit(pending.intent);
      if (mounted && careServiceIsCurrent(ref, pending.service)) {
        setState(() => _undo = null);
      }
    } on Object catch (error) {
      // See _takeNow: a refused command is never replayed.
      if (error is MedicationCommandBlocked) _undo = null;
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).t10_recordError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final workspace = ref.watch(workspaceContextProvider);
    final state = ref.watch(occurrenceDetailProvider(widget.occurrenceId));
    if (workspace.hasError || state.hasError) {
      return CareState(
        title: l.t08_unavailable,
        body: l.t08_unavailableBody,
        actionLabel: l.shared_retry,
        action: () =>
            ref.invalidate(occurrenceDetailProvider(widget.occurrenceId)),
      );
    }
    if (workspace.isLoading || state.isLoading || state.asData == null) {
      return CareState(title: l.shared_loading, loading: true);
    }
    final detail = state.requireValue;
    final row = detail.occurrence;
    final head = detail.head;
    final text = Theme.of(context).textTheme;
    final padding = widget.embedded
        ? const EdgeInsets.fromLTRB(24, 8, 24, 24)
        : const EdgeInsets.all(24);
    final children = <Widget>[
      _DoseHeader(detail: detail),
      if (row.pillId != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: MedicationPhotoCard(
            pillId: row.pillId!,
            name: detail.medicationName ?? '',
            maxHeight: 200,
          ),
        ),
      const SizedBox(height: 20),
      _DoseFigures(detail: detail),
      if (row.state == 'pending')
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            row.source == 'prn' ? l.t10_asNeededUndone : l.t10_unrecordedHint,
            style: text.bodySmall,
          ),
        ),
      if (row.state == 'missed')
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(l.dose_missedHint, style: text.bodySmall),
        ),
      const SizedBox(height: 20),
      LayoutBuilder(
        builder: (context, box) {
          final actions = _actions(context, detail);
          final previous = row.source == 'prn'
              ? null
              : PreviousSlotsList(occurrenceId: row.id);
          if (previous == null) return actions;
          if (box.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [actions, const SizedBox(height: 20), previous],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: actions),
              const SizedBox(width: 24),
              Expanded(child: previous),
            ],
          );
        },
      ),
      const SizedBox(height: 24),
      DoseStory(stations: doseStoryStations(context, detail)),
      const SizedBox(height: 24),
      CareFactLine(
        label: l.t10_planned,
        value: row.source == 'prn'
            ? l.t08_asNeeded
            : row.plannedLocalTime == null
            ? l.t08_unknownTime
            : '${row.plannedLocalDate} · ${clockText(context, row.plannedLocalTime!)}',
      ),
      CareFactLine(
        label: l.t08_amount,
        value: careAmountLabel(l, detail.plannedAmount),
      ),
      if (hasOriginalDosageText(detail.originalDosage))
        CareFactLine(label: l.t09_legacyDosage, value: detail.originalDosage!),
      if (row.provenance != 'exact') Text(l.t10_legacy),
      if (head != null && row.state == 'missed')
        // A miss is written by the app: it has an entry time only.
        CareFactLine(
          label: l.t10_entered,
          value: careInstantLabel(context, head.event.recordedAt),
        )
      else if (head != null) ...[
        CareFactLine(
          label: l.t10_actual,
          value: head.event.actualTimeKnown
              ? careInstantLabel(context, head.event.actualAt)
              : l.t08_unknownTime,
        ),
        CareFactLine(
          label: l.t10_entered,
          value: careInstantLabel(context, head.event.recordedAt),
        ),
        CareFactLine(
          label: l.t10_author,
          value:
              head.authorName ??
              (!head.authorKnown ? l.t10_unknownAuthor : l.t10_unnamedAuthor),
        ),
        CareFactLine(
          label: l.t10_recordedAmount,
          value: careAmountLabel(l, head.amount),
        ),
      ],
      if (detail.audit.isNotEmpty) ...[
        const SizedBox(height: 32),
        Text(l.t10_recordHistory, style: text.titleLarge),
        const SizedBox(height: 16),
        for (final fact in detail.audit.reversed) CareAuditEntry(fact: fact),
      ],
    ];
    return widget.embedded
        ? ListView(padding: padding, children: children)
        : ContentListView(padding: padding, children: children);
  }

  Widget _actions(BuildContext context, OccurrenceCareDetail detail) {
    final l = AppLocalizations.of(context);
    final row = detail.occurrence;
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(54)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    );
    final buttons = <Widget>[];
    if (row.source == 'prn' && row.state == 'pending') {
      // An undone as-needed dose has nothing left to record here.
    } else if (detail.canRecord) {
      if (row.state == 'pending' || row.state == 'missed') {
        buttons.addAll([
          FilledButton.icon(
            key: const ValueKey('dose-taken-now'),
            style: style,
            onPressed: _busy ? null : () => _takeNow(detail),
            icon: const Icon(Icons.check_circle_outline),
            label: Text(
              row.state == 'missed' ? l.dose_takeLateNow : l.t08_takenNow,
            ),
          ),
          OutlinedButton.icon(
            key: const ValueKey('dose-taken-other'),
            style: style,
            onPressed: _busy ? null : () => _record(detail),
            icon: const Icon(Icons.schedule),
            label: Text(l.tt_takenOtherTime),
          ),
          OutlinedButton.icon(
            key: const ValueKey('dose-skipped'),
            style: style,
            onPressed: _busy ? null : () => _record(detail, skip: true),
            icon: const Icon(Icons.block),
            label: Text(l.tt_skippedAction),
          ),
        ]);
      } else {
        buttons.add(
          FilledButton(
            style: style,
            onPressed: _busy ? null : () => _record(detail),
            child: Text(l.t10_correct),
          ),
        );
      }
    } else {
      buttons.add(Text(l.t10_readOnly));
    }
    if (detail.canUndo) {
      // A recorded miss is undone here, not on the Today card, so the card
      // keeps one Undo.
      buttons.add(
        OutlinedButton.icon(
          key: const ValueKey('dose-undo'),
          style: style,
          onPressed: _busy ? null : () => _withdraw(detail),
          icon: const Icon(Icons.undo),
          label: Text(row.state == 'missed' ? l.dose_undoMissed : l.t08_undo),
        ),
      );
    }
    if (_error != null) {
      buttons.add(
        Semantics(
          liveRegion: true,
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          buttons[i],
        ],
      ],
    );
  }
}

/// The medication, who it is for and when it is planned.
class _DoseHeader extends StatelessWidget {
  const _DoseHeader({required this.detail});
  final OccurrenceCareDetail detail;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final row = detail.occurrence;
    final time = row.plannedLocalTime;
    final subtitle = row.source == 'prn'
        ? l.t08_asNeeded
        : time == null
        ? l.t08_unknownTime
        : () {
            final parts = time.split(':');
            final hour = int.tryParse(parts.first);
            final minute = parts.length > 1 ? int.tryParse(parts[1]) : null;
            final planned = l.story_plannedFor(clockText(context, time));
            if (hour == null || minute == null) return planned;
            final part = dayPartLabel(
              l,
              dayPartOf(TimeOfDay(hour: hour, minute: minute)),
            );
            return '$planned · $part';
          }();
    final medication = detail.currentMedication;
    final scale = MediaQuery.textScalerOf(context);
    final markSize = scale.scale(30).clamp(30.0, 46.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.t08_forPerson(detail.personName ?? l.t10_unknownPerson),
          style: text.titleMedium,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: .6),
                borderRadius: BorderRadius.circular(16),
              ),
              child: PillMark(
                size: markSize,
                pillId: row.pillId ?? row.id,
                name: detail.medicationName ?? '',
                color: medicationTint(
                  id: row.pillId ?? row.id,
                  color: medication?.color,
                ),
                fallbackShape: medicationShapeOf(detail.plannedAmount.unit),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    detail.medicationName ?? l.t10_unknownMedication,
                    style: text.headlineMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: text.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Amount, state and, while the dose is still to record and its stock is
/// counted, how much is left once it is taken.
class _DoseFigures extends StatelessWidget {
  const _DoseFigures({required this.detail});
  final OccurrenceCareDetail detail;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final row = detail.occurrence;
    final stock = detail.currentStock?.whole;
    final exact = detail.exactAfterTaking;
    final after =
        (row.state == 'pending' || row.state == 'missed') &&
            row.source != 'prn' &&
            stock != null
        ? exact != null
              ? formatExactStock(
                  exact.isNegative ? ExactStock.zero : exact,
                  languageCode: Localizations.localeOf(context).languageCode,
                )
              : '${math.max(0, stock - 1)}'
        : null;
    final figures = [
      (l.t08_amount, careAmountLabel(l, detail.plannedAmount)),
      (
        l.tt_status,
        careOutcomeLabel(
          l,
          row.state,
          late: isTakenLate(row.state, detail.head?.event),
        ),
      ),
      if (after != null) (l.tt_afterTaking, l.tt_stockLeft(after)),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final stacked =
            box.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(16) > 22;
        final tiles = [
          for (final (label, value) in figures)
            _Figure(label: label, value: value),
        ];
        if (stacked && box.maxWidth < 360) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                tiles[i],
              ],
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: tiles[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '$label: $value',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: text.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The last few occurrences of the same slot ("Previous nights") with what
/// was recorded for each. Hidden when there is nothing earlier to list.
class PreviousSlotsList extends ConsumerWidget {
  const PreviousSlotsList({super.key, required this.occurrenceId});
  final String occurrenceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slots = ref.watch(previousSlotsProvider(occurrenceId)).asData?.value;
    final detail = ref.watch(occurrenceDetailProvider(occurrenceId)).asData;
    final planned = detail?.value.occurrence.plannedLocalTime;
    if (slots == null || slots.isEmpty || planned == null) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final parts = planned.split(':');
    final hour = int.tryParse(parts.first) ?? 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final title = switch (dayPartOf(TimeOfDay(hour: hour, minute: minute))) {
      DayPart.morning => l.tt_previousMornings,
      DayPart.afternoon => l.tt_previousAfternoons,
      DayPart.evening => l.tt_previousEvenings,
      DayPart.night => l.tt_previousNights,
    };
    final taken = slots.where((s) => s.taken).length;
    final locale = Localizations.localeOf(context).toString();
    // Newest first, as a person reads back through the nights.
    final ordered = slots.reversed.toList();
    return Container(
      key: const ValueKey('dose-previous-slots'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                l.tt_previousCount(taken, slots.length),
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < ordered.length; i++)
            _PreviousSlotRow(
              slot: ordered[i],
              locale: locale,
              last: i == ordered.length - 1,
            ),
        ],
      ),
    );
  }
}

class _PreviousSlotRow extends StatelessWidget {
  const _PreviousSlotRow({
    required this.slot,
    required this.locale,
    required this.last,
  });
  final PreviousSlot slot;
  final String locale;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final semantic = Theme.of(context).extension<AppSemanticColors>();
    final day = parseRoutineDate(slot.localDate);
    final weekday = DateFormat.E(locale).format(day);
    final time = slot.plannedLocalTime == null
        ? ''
        : clockText(context, slot.plannedLocalTime!);
    final when = time.isEmpty ? weekday : '$weekday $time';
    final tone = slot.taken
        ? semantic?.statusTaken ?? cs.primary
        : cs.onSurfaceVariant;
    final state = switch (slot.state) {
      'taken' =>
        slot.actualAt == null
            ? l.t08_taken
            : l.tt_previousTakenAt(clockAt(context, slot.actualAt!.toLocal())),
      'skipped' => l.t08_skipped,
      'missed' => l.dashboard_statusMissed,
      _ => l.t08_unrecorded,
    };
    return Semantics(
      container: true,
      label: l.tt_previousRow(when, state),
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            border: last
                ? null
                : Border(
                    bottom: BorderSide(
                      color: cs.outlineVariant.withValues(alpha: .6),
                    ),
                  ),
          ),
          child: Row(
            children: [
              Expanded(child: Text(when, style: text.bodyLarge)),
              const SizedBox(width: 8),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: slot.taken
                        ? tone.withValues(alpha: .14)
                        : cs.surfaceContainerHighest.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    state,
                    style: text.labelLarge?.copyWith(
                      color: slot.taken ? tone : cs.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CareAuditEntry extends StatelessWidget {
  const CareAuditEntry({super.key, required this.fact});
  final CareEventFacts fact;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final event = fact.event;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(switch (event.action) {
            'undo' => l.t10_withdrawn,
            'correct' => l.t10_corrected,
            'miss' => l.dose_markedMissedAuto,
            _ => careOutcomeLabel(l, event.toState),
          }, style: Theme.of(context).textTheme.titleMedium),
          if (event.action == 'undo' || event.action == 'correct')
            Text(
              careOutcomeLabel(
                l,
                event.toState,
                late: event.fromState == 'missed',
              ),
            ),
          const SizedBox(height: 12),
          // A miss is written by the app: it has an entry time only.
          if (event.action != 'miss') ...[
            CareFactLine(
              label: l.t10_actual,
              value: event.actualTimeKnown
                  ? careInstantLabel(context, event.actualAt)
                  : l.t08_unknownTime,
            ),
          ],
          CareFactLine(
            label: l.t10_entered,
            value: careInstantLabel(context, event.recordedAt),
          ),
          if (event.action != 'miss') ...[
            CareFactLine(
              label: l.t10_author,
              value:
                  fact.authorName ??
                  (!fact.authorKnown
                      ? l.t10_unknownAuthor
                      : l.t10_unnamedAuthor),
            ),
            CareFactLine(
              label: l.t10_recordedAmount,
              value: careAmountLabel(l, fact.amount),
            ),
          ],
          if (event.note?.isNotEmpty == true) Text(event.note!),
          const Divider(),
        ],
      ),
    );
  }
}
