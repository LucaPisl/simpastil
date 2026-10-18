/// How a problem report turns facts into text that is safe to post publicly.
///
/// The report is built from an allowlist, not filtered afterwards: a number
/// becomes a rough bucket, a time is rounded to the hour, and a word is kept
/// only if it matches a strict pattern. Anything that does not fit is dropped,
/// and the report says "unavailable" for it instead of guessing.
abstract final class ReportValue {
  static final _version = RegExp(
    r'^\d{1,3}\.\d{1,3}\.\d{1,3}(?:[-+][0-9A-Za-z.-]{1,24})?$',
  );
  static final _number = RegExp(r'^\d{1,6}$');
  static final _words = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+/-]{0,39}$');
  static final _id = RegExp(r'^[a-z][A-Za-z0-9_.-]{0,40}$');
  static final _code = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,63}$');
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _language = RegExp(r'^[a-z]{2}$');
  static final _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_$]{0,63}$');

  /// A release number such as `1.0.0` or `1.1.0-beta.1`.
  static String? version(String? value) =>
      value != null && _version.hasMatch(value) ? value : null;

  /// A whole number such as a build or schema number.
  static String? number(int? value) =>
      value != null && value >= 0 && _number.hasMatch('$value')
      ? '$value'
      : null;

  /// Short hardware words such as `samsung` or `SM-S938B`.
  static String? words(String? value) =>
      value != null && _words.hasMatch(value.trim()) ? value.trim() : null;

  /// A fixed lower-case identifier such as `flush.account`.
  static String? id(String? value) =>
      value != null && _id.hasMatch(value) ? value : null;

  /// An upper-case error code such as `SYNC_STAGE_FAILED`.
  static String? code(String? value) =>
      value != null && _code.hasMatch(value) ? value : null;

  /// A random request identifier that lets the maintainer find the same
  /// request in a server log. It carries no information of its own.
  static String? correlation(String? value) =>
      value != null && _uuid.hasMatch(value) ? value : null;

  static String? language(String? value) =>
      value != null && _language.hasMatch(value) ? value : null;

  /// A class name such as `StateError`.
  static String? typeName(String? value) =>
      value != null && _name.hasMatch(value) ? value : null;

  /// Only the status codes a server can really send.
  static String? httpStatus(int? value) =>
      value != null && value >= 100 && value <= 599 ? '$value' : null;

  /// How many of something, as a rough size: `0`, `1`, `2-5` or `6+`.
  static String count(int? value) {
    if (value == null) return unavailable;
    if (value <= 0) return '0';
    if (value == 1) return '1';
    return value <= 5 ? '2-5' : '6+';
  }

  /// How long ago, as a rough age.
  static String age(Duration? value) {
    if (value == null) return unavailable;
    final hours = value.inHours;
    if (value.isNegative || hours < 1) return 'under-1h';
    if (hours < 6) return '1-6h';
    if (hours < 24) return '6-24h';
    if (hours < 72) return '1-3d';
    if (hours < 168) return '3-7d';
    return 'over-7d';
  }

  /// How long something took, as a rough duration.
  static String took(Duration? value) {
    if (value == null) return unavailable;
    if (value.inMilliseconds < 1000) return 'under-1s';
    return value.inSeconds <= 5 ? '1-5s' : 'over-5s';
  }

  /// A moment rounded down to the hour, in UTC: `2026-10-18T14:00Z`.
  static String hour(DateTime value) {
    final utc = value.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
        '${two(utc.day)}T${two(utc.hour)}:00Z';
  }

  /// What a section shows when its facts could not be read.
  static const unavailable = 'unavailable';
}
