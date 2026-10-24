import '../db/database.dart';
import 'expiry.dart';

/// The phone-number characters the server accepts for a contact. Keep in step
/// with `CONTACT_PHONE_PATTERN` in the server's medication-details-extra
/// module.
final RegExp contactPhonePattern = RegExp(r'^[0-9+()./#* -]{3,40}$');

/// Longest as-needed limit and name the contract takes.
const int maxPrnPer24h = 24;

/// The largest values the server accepts. A pull keeps anything up to these,
/// even when this app's own form offers less, so a value another client set
/// is never erased.
const int wireMaxPrnPer24h = 48;
const int wireMaxPrnGapMinutes = 2880;
const int maxPrnGapMinutes = 1440;
const int maxContactNameLength = 120;

/// The optional medication extras of one medicine: as-needed limits, an
/// expiry date, and the prescriber and pharmacy contacts.
///
/// Every field is nullable and independent. Phone numbers and names are
/// personal data: they are stored and synced like the medicine and are never
/// logged.
class MedicationExtras {
  const MedicationExtras({
    this.prnMaxPer24h,
    this.prnMinGapMinutes,
    this.expiresOn,
    this.prescriberName,
    this.prescriberPhone,
    this.pharmacyName,
    this.pharmacyPhone,
  });

  static const none = MedicationExtras();

  factory MedicationExtras.fromPill(Pill pill) => MedicationExtras(
    prnMaxPer24h: pill.prnMaxPer24h,
    prnMinGapMinutes: pill.prnMinGapMinutes,
    expiresOn: pill.expiresOn,
    prescriberName: pill.prescriberName,
    prescriberPhone: pill.prescriberPhone,
    pharmacyName: pill.pharmacyName,
    pharmacyPhone: pill.pharmacyPhone,
  );

  final int? prnMaxPer24h;
  final int? prnMinGapMinutes;

  /// Calendar date `yyyy-MM-dd`, no time zone.
  final String? expiresOn;
  final String? prescriberName;
  final String? prescriberPhone;
  final String? pharmacyName;
  final String? pharmacyPhone;

  bool get hasPrescriber => prescriberName != null || prescriberPhone != null;
  bool get hasPharmacy => pharmacyName != null || pharmacyPhone != null;
  bool get hasLimits => prnMaxPer24h != null || prnMinGapMinutes != null;
  bool get isEmpty =>
      !hasLimits && expiresOn == null && !hasPrescriber && !hasPharmacy;

  /// The wire keys, every one present (null clears). Used by pending
  /// operation payloads; the adapter drops them when the server lacks the
  /// contract.
  Map<String, Object?> toPayload() => {
    'prnMaxPer24h': prnMaxPer24h,
    'prnMinGapMinutes': prnMinGapMinutes,
    'expiresOn': expiresOn,
    'prescriberName': prescriberName,
    'prescriberPhone': prescriberPhone,
    'pharmacyName': pharmacyName,
    'pharmacyPhone': pharmacyPhone,
  };

  MedicationExtras copyWith({
    Object? prnMaxPer24h = _keep,
    Object? prnMinGapMinutes = _keep,
    Object? expiresOn = _keep,
    Object? prescriberName = _keep,
    Object? prescriberPhone = _keep,
    Object? pharmacyName = _keep,
    Object? pharmacyPhone = _keep,
  }) => MedicationExtras(
    prnMaxPer24h: identical(prnMaxPer24h, _keep)
        ? this.prnMaxPer24h
        : prnMaxPer24h as int?,
    prnMinGapMinutes: identical(prnMinGapMinutes, _keep)
        ? this.prnMinGapMinutes
        : prnMinGapMinutes as int?,
    expiresOn: identical(expiresOn, _keep)
        ? this.expiresOn
        : expiresOn as String?,
    prescriberName: identical(prescriberName, _keep)
        ? this.prescriberName
        : prescriberName as String?,
    prescriberPhone: identical(prescriberPhone, _keep)
        ? this.prescriberPhone
        : prescriberPhone as String?,
    pharmacyName: identical(pharmacyName, _keep)
        ? this.pharmacyName
        : pharmacyName as String?,
    pharmacyPhone: identical(pharmacyPhone, _keep)
        ? this.pharmacyPhone
        : pharmacyPhone as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is MedicationExtras &&
      other.prnMaxPer24h == prnMaxPer24h &&
      other.prnMinGapMinutes == prnMinGapMinutes &&
      other.expiresOn == expiresOn &&
      other.prescriberName == prescriberName &&
      other.prescriberPhone == prescriberPhone &&
      other.pharmacyName == pharmacyName &&
      other.pharmacyPhone == pharmacyPhone;

  @override
  int get hashCode => Object.hash(
    prnMaxPer24h,
    prnMinGapMinutes,
    expiresOn,
    prescriberName,
    prescriberPhone,
    pharmacyName,
    pharmacyPhone,
  );

  // Deliberately no field values: this object holds personal data.
  @override
  String toString() => 'MedicationExtras(${isEmpty ? 'empty' : 'set'})';
}

const Object _keep = Object();

/// Reads the wire value of an extras key tolerantly: a wrong type is treated
/// as unset so a pull never rejects.
int? wireExtrasInt(Object? raw, {required int max}) =>
    raw is int && raw >= 1 && raw <= max ? raw : null;

String? wireExtrasName(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  return text.length > maxContactNameLength
      ? text.substring(0, maxContactNameLength)
      : text;
}

String? wireExtrasPhone(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  return contactPhonePattern.hasMatch(text) ? text : null;
}

final RegExp _dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');

String? wireExtrasDate(Object? raw) {
  if (raw is! String || !_dateOnly.hasMatch(raw)) return null;
  return parseExpiryDate(raw) == null ? null : raw;
}
