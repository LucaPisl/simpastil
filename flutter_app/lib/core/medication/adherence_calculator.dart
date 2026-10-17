/// A read-only occurrence projection accepted by [AdherenceCalculator].
class AdherenceOccurrence {
  const AdherenceOccurrence({
    required this.id,
    required this.source,
    required this.expected,
    required this.plannedAt,
    required this.state,
    required this.provenance,
    this.superseded = false,
    this.pillId,
    this.pillName,
    this.dosage,
    this.profileId,
    this.plannedLocalDate,
  });

  final String id;
  final String source;
  final bool expected;
  final DateTime? plannedAt;
  final String state;
  final String provenance;
  final bool superseded;
  final String? pillId;
  final String? pillName;
  final String? dosage;
  final String? profileId;
  final String? plannedLocalDate;
}

/// Append-only event metadata; state itself remains authoritative on the
/// occurrence projection and is not re-reduced here.
class AdherenceEvent {
  const AdherenceEvent({
    required this.occurrenceId,
    required this.resultVersion,
    required this.action,
    required this.toState,
    required this.actualAt,
    required this.actualTimeKnown,
    required this.recordedAt,
    required this.origin,
    this.note,
  });

  final String occurrenceId;
  final int resultVersion;
  final String action;
  final String toState;
  final DateTime? actualAt;
  final bool actualTimeKnown;
  final DateTime recordedAt;
  final String origin;
  final String? note;
}

class AdherenceHistoryItem {
  const AdherenceHistoryItem({
    required this.occurrenceId,
    required this.source,
    required this.expected,
    required this.superseded,
    required this.isDueScheduled,
    required this.status,
    required this.provenance,
    required this.plannedAt,
    required this.actualAt,
    required this.actualTimeKnown,
    required this.note,
    required this.pillId,
    required this.pillName,
    required this.dosage,
    required this.profileId,
    required this.plannedLocalDate,
  });

  final String occurrenceId;
  final String source;
  final bool expected;
  final bool superseded;
  final bool isDueScheduled;
  final String status;
  final String provenance;
  final DateTime? plannedAt;
  final DateTime? actualAt;
  final bool actualTimeKnown;
  final String? note;
  final String? pillId;
  final String? pillName;
  final String? dosage;
  final String? profileId;
  final String? plannedLocalDate;
}

class AdherenceSummary {
  const AdherenceSummary({
    required this.dueScheduled,
    required this.takenScheduled,
    required this.skippedScheduled,
    required this.missedScheduled,
    required this.unrecordedScheduled,
    required this.scheduledAdherence,
    required this.prnTaken,
    required this.history,
    required this.provenanceCounts,
  });

  final int dueScheduled;
  final int takenScheduled;
  final int skippedScheduled;

  /// Due doses the app recorded as missed (an event in the ledger).
  final int missedScheduled;

  /// Due doses nobody has recorded at all: still pending, not recorded
  /// as missed. A dose that is recorded missed is [missedScheduled], never
  /// this.
  final int unrecordedScheduled;
  final double? scheduledAdherence;
  final int prnTaken;
  final List<AdherenceHistoryItem> history;
  final Map<String, int> provenanceCounts;
}

/// The sole scheduled-adherence definition shared by app surfaces:
/// taken-and-due scheduled occurrences / all due scheduled occurrences.
/// Skipped, missed and unrecorded occurrences all remain in the denominator,
/// so a dose that was taken late counts as taken and a recorded miss counts
/// against adherence exactly as an unrecorded dose does. "Missed" is only a
/// dose that has a recorded miss; a due dose with nothing recorded is
/// "unrecorded". PRN and non-expected legacy history never enter scheduled
/// adherence.
class AdherenceCalculator {
  const AdherenceCalculator();

  AdherenceSummary calculate({
    required DateTime now,
    required Iterable<AdherenceOccurrence> occurrences,
    required Iterable<AdherenceEvent> events,
  }) {
    final eventsByOccurrence = <String, List<AdherenceEvent>>{};
    for (final event in events) {
      (eventsByOccurrence[event.occurrenceId] ??= []).add(event);
    }
    for (final occurrenceEvents in eventsByOccurrence.values) {
      occurrenceEvents.sort((a, b) {
        final byVersion = a.resultVersion.compareTo(b.resultVersion);
        return byVersion != 0
            ? byVersion
            : a.recordedAt.compareTo(b.recordedAt);
      });
    }

    var due = 0;
    var taken = 0;
    var skipped = 0;
    var missed = 0;
    var unrecorded = 0;
    var prnTaken = 0;
    final provenanceCounts = <String, int>{};
    final history = <AdherenceHistoryItem>[];

    for (final occurrence in occurrences) {
      final occurrenceEvents = eventsByOccurrence[occurrence.id] ?? const [];
      final relevantEvent = _latestStateEvent(occurrence, occurrenceEvents);
      final isSuperseded = occurrence.superseded;
      final isDueScheduled =
          occurrence.source == 'scheduled' &&
          occurrence.expected &&
          !isSuperseded &&
          occurrence.plannedAt != null &&
          !occurrence.plannedAt!.isAfter(now);

      var status = occurrence.state;
      if (isDueScheduled && occurrence.state == 'pending') {
        status = 'unrecorded';
      }
      if (occurrence.source == 'prn' &&
          occurrence.state == 'taken' &&
          !isSuperseded) {
        prnTaken++;
      }
      if (isDueScheduled) {
        due++;
        if (occurrence.state == 'taken') taken++;
        if (occurrence.state == 'skipped') skipped++;
        if (occurrence.state == 'missed') missed++;
        if (status == 'unrecorded') unrecorded++;
      }
      provenanceCounts.update(
        occurrence.provenance,
        (count) => count + 1,
        ifAbsent: () => 1,
      );

      history.add(
        AdherenceHistoryItem(
          occurrenceId: occurrence.id,
          source: occurrence.source,
          expected: occurrence.expected,
          superseded: isSuperseded,
          isDueScheduled: isDueScheduled,
          status: status,
          provenance: occurrence.provenance,
          plannedAt: occurrence.plannedAt,
          actualAt: relevantEvent?.actualTimeKnown == true
              ? relevantEvent!.actualAt
              : null,
          actualTimeKnown: relevantEvent?.actualTimeKnown ?? false,
          note: relevantEvent?.note,
          pillId: occurrence.pillId,
          pillName: occurrence.pillName,
          dosage: occurrence.dosage,
          profileId: occurrence.profileId,
          plannedLocalDate: occurrence.plannedLocalDate,
        ),
      );
    }

    history.sort((a, b) {
      final aAt = a.actualAt ?? a.plannedAt;
      final bAt = b.actualAt ?? b.plannedAt;
      if (aAt == null) {
        return bAt == null ? a.occurrenceId.compareTo(b.occurrenceId) : 1;
      }
      if (bAt == null) return -1;
      final byTime = aAt.compareTo(bAt);
      return byTime != 0 ? byTime : a.occurrenceId.compareTo(b.occurrenceId);
    });

    return AdherenceSummary(
      dueScheduled: due,
      takenScheduled: taken,
      skippedScheduled: skipped,
      missedScheduled: missed,
      unrecordedScheduled: unrecorded,
      scheduledAdherence: due == 0 ? null : taken / due,
      prnTaken: prnTaken,
      history: List.unmodifiable(history),
      provenanceCounts: Map.unmodifiable(provenanceCounts),
    );
  }

  AdherenceEvent? _latestStateEvent(
    AdherenceOccurrence occurrence,
    List<AdherenceEvent> events,
  ) {
    for (final event in events.reversed) {
      if (event.toState == occurrence.state) return event;
    }
    return null;
  }
}
