import 'dart:async';

import 'package:flutter/widgets.dart';

import 'diagnostic_event.dart';
import 'diagnostics_recorder.dart';
import 'process_exit.dart';
import 'report/report_channel.dart';
import 'session_marker.dart';

export 'process_exit.dart';

/// A run that ended while the app was in front of the person.
class CrashIncident {
  const CrashIncident({required this.at, this.exit});

  /// The last moment the previous run was known to be in front.
  final DateTime at;

  /// What Android recorded about that ending, when it could be read.
  final ProcessExit? exit;
}

/// Starts the diagnostics for one run of the app: the session marker, the
/// lifecycle hooks, and the check for how the previous run ended.
///
/// Starting is best effort and never throws. The one thing it hands back is the
/// [CrashIncident] of the previous run, if there was one the person has not
/// already dealt with.
class DiagnosticsSession with WidgetsBindingObserver {
  DiagnosticsSession({
    DiagnosticsRecorder? recorder,
    Future<ProcessExit?> Function()? lastProcessExit,
  }) : _recorder = recorder ?? DiagnosticsRecorder.shared,
       _lastProcessExit = lastProcessExit;

  static final DiagnosticsSession shared = DiagnosticsSession(
    lastProcessExit: ReportChannel().lastExit,
  );

  final DiagnosticsRecorder _recorder;
  Future<ProcessExit?> Function()? _lastProcessExit;
  Future<void>? _started;
  SessionMarker? _marker;
  CrashIncident? _incident;

  /// Lets the Android channel supply how the last process ended.
  set lastProcessExit(Future<ProcessExit?> Function()? reader) =>
      _lastProcessExit = reader;

  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    try {
      final dir = await _recorder.directory;
      if (dir == null) return;
      final marker = _marker = SessionMarker(dir);
      final lastSeen = await marker.begin();
      if (lastSeen != null) {
        final exit = await _readExit(lastSeen);
        if (exit == null || !exit.benign) {
          _incident = CrashIncident(at: lastSeen, exit: exit);
          await _recorder.record(
            DiagnosticEvent(
              kind: DiagnosticKind.uncleanEnd,
              at: lastSeen,
              code: exit == null ? null : _codeFor(exit.reason),
            ),
          );
        }
      }
      await _recorder.record(
        DiagnosticEvent(
          kind: DiagnosticKind.appStarted,
          at: DateTime.now().toUtc(),
        ),
      );
      WidgetsBinding.instance.addObserver(this);
    } on Object {
      // Diagnostics must never stop the app from opening.
    }
  }

  Future<ProcessExit?> _readExit(DateTime lastSeen) async {
    try {
      final exit = await _lastProcessExit?.call();
      if (exit == null) return null;
      // An older record belongs to an earlier run, not to the one that just
      // ended after [lastSeen].
      if (exit.at.isBefore(lastSeen.subtract(const Duration(seconds: 2)))) {
        return null;
      }
      return ProcessExit(
        reason: ProcessExit.knownReasons.contains(exit.reason)
            ? exit.reason
            : 'other',
        at: exit.at,
      );
    } on Object {
      return null;
    }
  }

  static String _codeFor(String reason) => 'EXIT_${reason.toUpperCase()}';

  /// The previous run's ending, unless the person already dismissed it.
  Future<CrashIncident?> pendingIncident() async {
    await start();
    final incident = _incident;
    final marker = _marker;
    if (incident == null || marker == null) return null;
    final dismissed = await marker.dismissedAt();
    if (dismissed != null && !incident.at.isAfter(dismissed)) return null;
    return incident;
  }

  /// Remembers that the notice for the current incident was dealt with.
  Future<void> dismissIncident() async {
    final incident = _incident;
    final marker = _marker;
    if (incident == null || marker == null) return;
    await marker.dismiss(incident.at);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final marker = _marker;
    if (marker == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(marker.markForeground());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(marker.markBackground());
      case AppLifecycleState.inactive:
        // A permission dialog or the notification shade: still in front.
        break;
    }
  }
}
