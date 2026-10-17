import '../db/database.dart' show OccurrenceEvent;

/// Whether a dose in [state] was taken after it had been recorded as missed.
///
/// The taking is a `correct` event whose previous state was `missed`; it is
/// the dose's current head. Taking it again after other corrections no longer
/// counts as late, because the head then moves from another state.
bool isTakenLate(String state, OccurrenceEvent? head) =>
    state == 'taken' &&
    head != null &&
    head.action == 'correct' &&
    head.fromState == 'missed';
