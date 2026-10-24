import 'package:uuid/uuid.dart';

/// Stable ids for care copied from this phone's own care to an account.
///
/// Each copied record's id depends only on the account and the local record
/// it came from, so a Move that stops halfway and runs again writes the same
/// records instead of duplicates, and a server that already has one simply
/// keeps it.
class MoveIds {
  const MoveIds(this.accountOwnerId);

  /// The connected account's owner id; ids never repeat across accounts.
  final String accountOwnerId;

  String _id(String kind, String local) => const Uuid().v5(
    Namespace.url.value,
    'simpastil-move:v1:$accountOwnerId:$kind:$local',
  );

  String person(String localProfileId) => _id('person', localProfileId);

  String medication(String localPillId) => _id('medication', localPillId);

  /// The schedule carrying one routine slot. A slot's routine in force today
  /// owns the plain id; a version that starts later gets its own schedule,
  /// keyed by that version's revision.
  String schedule(String routineId, String slotId, {int? revision}) => _id(
    'schedule',
    revision == null ? '$routineId:$slotId' : '$routineId:$slotId:$revision',
  );

  String occurrence(String localOccurrenceId) =>
      _id('occurrence', localOccurrenceId);

  /// The one command that records a copied dose's final state.
  String command(String localOccurrenceId) => _id('command', localOccurrenceId);
}
