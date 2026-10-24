import 'package:drift/drift.dart';

import 'profiles_table.dart';

@DataClassName('Pill')
class Pills extends Table {
  @override
  String get tableName => 'pills';

  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(Profiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get dosage => text().nullable()(); // e.g. "10mg"
  TextColumn get notes => text().nullable()();
  TextColumn get color => text().nullable()(); // hex e.g. "#FF5733"
  IntColumn get currentStock => integer().nullable()();

  /// The exact stock as a decimal string, set once the stock is counted in a
  /// unit (see [stockUnit]). Null means a plain whole count held in
  /// [currentStock]; when set, [currentStock] mirrors its floor so older
  /// readers keep a whole number.
  TextColumn get stockQuantity => text().nullable()();

  /// What [stockQuantity] counts (`tablet`, `ml`). Null for a plain count.
  TextColumn get stockUnit => text().nullable()();

  /// True while the count is only a last known count: a dose was recorded with
  /// an amount the count cannot hold exactly (a third of a tablet), so the
  /// count was left alone. Mirrors the server's flag on a connected account;
  /// a count (even an unchanged one) clears it.
  BoolColumn get stockNeedsRecount =>
      boolean().withDefault(const Constant(false))();
  IntColumn get lowStockThreshold => integer().nullable()();
  BoolColumn get isPrn => boolean().withDefault(const Constant(false))();

  /// The silhouette the person picked, as its wire name (`round`, `caplet`,
  /// ...). Null until one is picked: the mark then draws the shape derived
  /// from the medication's form. May hold a name a newer build wrote; readers
  /// map anything they do not know to the derived shape.
  TextColumn get shape => text().nullable()();

  /// Most as-needed doses allowed in a rolling 24 hours (1 to 48), or null for
  /// no limit. The check warns before going over; it never blocks a dose.
  IntColumn get prnMaxPer24h => integer().nullable().named('prn_max_per_24h')();

  /// Fewest minutes allowed between as-needed doses (1 to 2880), or null.
  IntColumn get prnMinGapMinutes => integer().nullable()();

  /// The day the medication expires, as `YYYY-MM-DD` (a calendar date with no
  /// time zone), or null.
  TextColumn get expiresOn => text().nullable()();

  /// Who prescribed it and where it is filled: a name and a phone number each,
  /// all optional. Personal data: never logged, never in a notification.
  TextColumn get prescriberName => text().nullable()();
  TextColumn get prescriberPhone => text().nullable()();
  TextColumn get pharmacyName => text().nullable()();
  TextColumn get pharmacyPhone => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  // ── Sync metadata ─────────────────────────────────────────────────────────
  TextColumn get serverId => text().nullable().unique()();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();
  IntColumn get lastSyncAt => integer().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
