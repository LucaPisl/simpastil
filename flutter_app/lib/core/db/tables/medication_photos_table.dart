import 'package:drift/drift.dart';

import 'pills_table.dart';

/// The one photo a medication may carry, kept inside the protected database so
/// no loose image file ever exists on the device.
///
/// The bytes are the already cleaned JPEG (no metadata, at most 1600 px a side
/// and about 300 KB), held as base64 text so a backup carries them through the
/// same text-only row format as every other column.
@DataClassName('MedicationPhoto')
class MedicationPhotos extends Table {
  @override
  String get tableName => 'medication_photos';

  TextColumn get pillId =>
      text().references(Pills, #id, onDelete: KeyAction.cascade)();

  /// The JPEG as base64. Empty while the photo is only known by hash and still
  /// has to be downloaded ([syncStatus] `fetch`).
  TextColumn get bytesBase64 => text().withDefault(const Constant(''))();

  /// Lowercase hex SHA-256 of the JPEG bytes.
  TextColumn get sha256 => text()();

  /// The photo revision the server last confirmed, or 0 before the first
  /// upload.
  IntColumn get revision => integer().withDefault(const Constant(0))();

  /// `pending` (upload needed), `removing` (delete needed), `fetch` (the server
  /// holds a different photo to download), `synced`, `rejected` (the server
  /// refused the upload; kept on this device only) or `local` (a workspace that
  /// never syncs).
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();

  /// The hash the server advertised while [syncStatus] is `fetch`.
  TextColumn get remoteSha256 => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {pillId};
}
