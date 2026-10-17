import 'medication_amount.dart';

/// The reviewed medication details as the account carries them, beside the
/// medicine's own fields in a `pill.create` or `pill.update` payload.
///
/// One builder for every sender, so a review saved from the medicine page and
/// one carried up by the backfill are byte for byte the same request. A server
/// that does not store these refuses unknown fields, so the adapter leaves
/// them out; the names here match the server's pill schema exactly.
Map<String, Object?> medicationDetailWire({
  required MedicationAmount amount,
  required String? packageStrength,
  required String? form,
  required bool legacyDosageReviewed,
}) => {
  'amountPerUse': amount.isUnknown ? null : amount.toJson(),
  'packageStrength': packageStrength,
  'form': form,
  'legacyDosageReviewed': legacyDosageReviewed,
};
