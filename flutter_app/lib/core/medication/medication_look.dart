import 'package:drift/drift.dart';

import '../db/database.dart';
import 'medication_shape.dart';

/// How one medication is drawn: its silhouette and the letter(s) debossed on
/// it. Colour is separate (see `medicationTint`).
class MedicationLook {
  const MedicationLook({required this.shape, required this.imprint});

  final MedicationShape shape;

  /// One letter, or two when another of the person's medications shares both
  /// the shape and the first letter. Empty when the name has no letter.
  final String imprint;

  @override
  bool operator ==(Object other) =>
      other is MedicationLook &&
      other.shape == shape &&
      other.imprint == imprint;

  @override
  int get hashCode => Object.hash(shape, imprint);

  @override
  String toString() => 'MedicationLook($shape, "$imprint")';
}

/// What [buildMedicationLooks] needs of one medication.
typedef MedicationLookRow = ({
  String id,
  String personId,
  String name,
  String? shape,
  String? form,
});

/// The shape one medication is drawn with: the one picked for it, else the one
/// its form implies. A name this build does not know (a newer server's) is
/// the same as none.
MedicationShape effectiveMedicationShape(String? picked, String? form) =>
    MedicationShape.fromWire(picked) ?? deriveMedicationShape(form);

/// The look of every medication in [rows], by medication id. Imprints are
/// resolved per person, because two people's medicine cabinets are never
/// confused with one another.
Map<String, MedicationLook> buildMedicationLooks(
  Iterable<MedicationLookRow> rows,
) {
  final byPerson = <String, List<MedicationLookRow>>{};
  for (final row in rows) {
    byPerson.putIfAbsent(row.personId, () => []).add(row);
  }
  final looks = <String, MedicationLook>{};
  for (final person in byPerson.values) {
    final shapes = {
      for (final r in person) r.id: effectiveMedicationShape(r.shape, r.form),
    };
    final imprints = medicationImprints([
      for (final r in person) (id: r.id, name: r.name, shape: shapes[r.id]!),
    ]);
    for (final r in person) {
      looks[r.id] = MedicationLook(
        shape: shapes[r.id]!,
        imprint: imprints[r.id]!,
      );
    }
  }
  return looks;
}

/// Reads the look rows of every live medication of [ownerUserId] from [db]:
/// what a widget or a background job needs without a provider scope.
Future<List<MedicationLookRow>> readMedicationLookRows(
  AppDatabase db,
  String ownerUserId,
) async {
  final query =
      db.select(db.pills).join([
        innerJoin(db.profiles, db.profiles.id.equalsExp(db.pills.profileId)),
        leftOuterJoin(
          db.medicationDetails,
          db.medicationDetails.pillId.equalsExp(db.pills.id),
        ),
      ])..where(
        db.profiles.userId.equals(ownerUserId) &
            db.profiles.isDeleted.equals(false) &
            db.pills.isDeleted.equals(false),
      );
  return [
    for (final row in await query.get())
      (
        id: row.readTable(db.pills).id,
        personId: row.readTable(db.pills).profileId,
        name: row.readTable(db.pills).name,
        shape: row.readTable(db.pills).shape,
        form: row.readTableOrNull(db.medicationDetails)?.form,
      ),
  ];
}
