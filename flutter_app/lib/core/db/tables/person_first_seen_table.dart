import 'package:drift/drift.dart';

import 'profiles_table.dart';

/// The moment THIS PHONE first knew a person. Device-local: never synced,
/// never sent to the server and not part of portable backups.
///
/// Rows are stamped by the `profiles_first_seen` trigger on every insert path
/// (local create, sync pull, import, restore) and removed with the profile.
@DataClassName('PersonFirstSeenRow')
class PersonFirstSeen extends Table {
  @override
  String get tableName => 'person_first_seen';

  TextColumn get profileId =>
      text().references(Profiles, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get firstSeenAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {profileId};
}
