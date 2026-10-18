import 'dart:convert';
import 'dart:io';

/// A tiny file that says whether the app was in front of the person when the
/// process last stopped.
///
/// The app writes "foreground" when it comes to the front and "background"
/// the moment it leaves it. Android does not tell an app that it is about to be
/// killed, but it does not kill a visible app unless something went wrong: a
/// crash, a hang, or running out of memory. So a file that still says
/// "foreground" on the next start means the last run ended badly, and that is
/// the one thing a normal log cannot capture.
class SessionMarker {
  SessionMarker(this._directory, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const _fileName = 'session.json';
  final Directory _directory;
  final DateTime Function() _clock;

  File get _file =>
      File('${_directory.path}${Platform.pathSeparator}$_fileName');

  /// Starts a run. Returns when the previous one was last seen in front if it
  /// ended there, null if it ended in the background or there was none.
  Future<DateTime?> begin() async {
    final previous = await _read();
    await _write(foreground: true, dismissed: previous.dismissed);
    return previous.foreground ? previous.at : null;
  }

  /// The app came to the front.
  Future<void> markForeground() async {
    final previous = await _read();
    await _write(foreground: true, dismissed: previous.dismissed);
  }

  /// The app left the front: from here on, being stopped is normal.
  Future<void> markBackground() async {
    final previous = await _read();
    await _write(foreground: false, dismissed: previous.dismissed);
  }

  /// When the person last dismissed a crash notice (the incident time it was
  /// about), or null.
  Future<DateTime?> dismissedAt() async => (await _read()).dismissed;

  /// Remembers that the notice for an incident at [incidentAt] was dealt with,
  /// so the same incident is never announced twice.
  Future<void> dismiss(DateTime incidentAt) async {
    final previous = await _read();
    await _write(
      foreground: previous.foreground,
      dismissed: incidentAt.toUtc(),
      at: previous.at,
    );
  }

  Future<({bool foreground, DateTime? at, DateTime? dismissed})> _read() async {
    try {
      final file = _file;
      if (!file.existsSync()) {
        return (foreground: false, at: null, dismissed: null);
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> || decoded['v'] != 1) {
        return (foreground: false, at: null, dismissed: null);
      }
      return (
        foreground: decoded['state'] == 'foreground',
        at: _time(decoded['at']),
        dismissed: _time(decoded['dismissed']),
      );
    } on Object {
      return (foreground: false, at: null, dismissed: null);
    }
  }

  Future<void> _write({
    required bool foreground,
    DateTime? dismissed,
    DateTime? at,
  }) async {
    try {
      await _directory.create(recursive: true);
      final body = jsonEncode({
        'v': 1,
        'state': foreground ? 'foreground' : 'background',
        'at': (at ?? _clock()).toUtc().toIso8601String(),
        if (dismissed != null) 'dismissed': dismissed.toUtc().toIso8601String(),
      });
      // Write beside the file and rename over it, so a kill in the middle of
      // the write leaves the old, whole file rather than half of a new one.
      final temporary = File('${_file.path}.tmp');
      await temporary.writeAsString(body, flush: true);
      await temporary.rename(_file.path);
    } on Object {
      // A marker that cannot be written only costs a missed crash notice.
    }
  }

  static DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}
