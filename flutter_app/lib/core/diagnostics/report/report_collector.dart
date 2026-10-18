import 'dart:async';

import '../diagnostic_event.dart';
import '../diagnostics_recorder.dart';
import 'diagnostic_report.dart';

/// Reads one section of the report. Returns null (or throws) when the facts
/// cannot be read right now; the report then says "unavailable" for it.
typedef ReportSource<T> = Future<T?> Function();

/// Where each section of a problem report comes from.
///
/// Every source is optional and independent, so the report can be built from
/// whatever still works: a crash in the database must not take the device
/// facts down with it.
class ReportSources {
  const ReportSources({
    this.app,
    this.device,
    this.permissions,
    this.data,
    this.sync,
    this.capabilities,
    this.lastStop,
  });

  final ReportSource<ReportApp>? app;
  final ReportSource<ReportDevice>? device;
  final ReportSource<ReportPermissions>? permissions;
  final ReportSource<ReportData>? data;
  final ReportSource<ReportSync>? sync;
  final ReportSource<List<ReportCapability>>? capabilities;

  /// How the previous run ended, as a code such as `EXIT_CRASH`.
  final ReportSource<String>? lastStop;

  /// These sources, with any that [other] has taking the place of mine.
  ReportSources merge(ReportSources other) => ReportSources(
    app: other.app ?? app,
    device: other.device ?? device,
    permissions: other.permissions ?? permissions,
    data: other.data ?? data,
    sync: other.sync ?? sync,
    capabilities: other.capabilities ?? capabilities,
    lastStop: other.lastStop ?? lastStop,
  );
}

/// Builds the report now. Never throws: a source that fails or takes longer
/// than [timeout] leaves its section "unavailable", and the rest is kept.
Future<DiagnosticReport> collectReport(
  ReportSources sources, {
  DiagnosticsRecorder? recorder,
  DateTime? now,
  Duration timeout = const Duration(seconds: 4),
}) async {
  Future<T?> read<T>(ReportSource<T>? source) async {
    if (source == null) return null;
    try {
      return await source().timeout(timeout);
    } on Object {
      return null;
    }
  }

  final results = await Future.wait<Object?>([
    read(sources.app),
    read(sources.device),
    read(sources.permissions),
    read(sources.data),
    read(sources.sync),
    read(sources.capabilities),
    read(sources.lastStop),
    (recorder ?? DiagnosticsRecorder.shared).recent(),
  ]);
  return DiagnosticReport(
    createdAt: now ?? DateTime.now().toUtc(),
    app: results[0] as ReportApp?,
    device: results[1] as ReportDevice?,
    permissions: results[2] as ReportPermissions?,
    data: results[3] as ReportData?,
    sync: results[4] as ReportSync?,
    capabilities: results[5] as List<ReportCapability>?,
    lastStop: results[6] as String?,
    events: results[7]! as List<DiagnosticEvent>,
  );
}
