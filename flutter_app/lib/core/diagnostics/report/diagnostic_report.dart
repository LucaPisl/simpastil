import '../diagnostic_event.dart';
import 'report_values.dart';

enum ReportPermission {
  allowed('allowed'),
  denied('denied'),
  unknown('unknown');

  const ReportPermission(this.wireName);
  final String wireName;
}

enum ReportScreen {
  phone('phone'),
  tablet('tablet');

  const ReportScreen(this.wireName);
  final String wireName;
}

/// How the app is installed: its release, its database schema and language.
class ReportApp {
  ReportApp({String? version, int? build, int? database, String? language})
    : version = ReportValue.version(version),
      build = ReportValue.number(build),
      database = ReportValue.number(database),
      language = ReportValue.language(language);

  final String? version;
  final String? build;
  final String? database;
  final String? language;
}

/// The phone or tablet the app runs on: hardware facts only.
class ReportDevice {
  ReportDevice({
    String? androidRelease,
    int? sdk,
    String? maker,
    String? model,
    this.screen,
  }) : androidRelease = ReportValue.words(androidRelease),
       sdk = ReportValue.number(sdk),
       maker = ReportValue.words(maker),
       model = ReportValue.words(model);

  final String? androidRelease;
  final String? sdk;
  final String? maker;
  final String? model;
  final ReportScreen? screen;
}

/// Whether the permissions reminders depend on are granted.
class ReportPermissions {
  const ReportPermissions({
    this.notifications,
    this.exactAlarms,
    this.batteryUnrestricted,
  });

  final ReportPermission? notifications;
  final ReportPermission? exactAlarms;

  /// True when the app is exempt from battery optimisation.
  final ReportPermission? batteryUnrestricted;
}

/// How much is stored, as rough sizes only. The names stay out.
class ReportData {
  const ReportData({
    this.profiles,
    this.medicines,
    this.schedules,
    this.doseRecords,
    this.scheduledReminders,
  });

  final int? profiles;
  final int? medicines;
  final int? schedules;
  final int? doseRecords;
  final int? scheduledReminders;
}

/// One step of the last sync run.
class ReportSyncStage {
  ReportSyncStage({
    required String id,
    required this.status,
    String? code,
    int? httpStatus,
    int? retries,
    this.took,
    String? correlationId,
  }) : id = ReportValue.id(id) ?? 'unknown',
       code = ReportValue.code(code),
       httpStatus = ReportValue.httpStatus(httpStatus),
       retries = ReportValue.number(retries),
       correlationId = ReportValue.correlation(correlationId);

  final String id;

  /// `succeeded`, `partiallySynced`, `failed` or `blocked`.
  final String status;
  final String? code;
  final String? httpStatus;
  final String? retries;
  final Duration? took;
  final String? correlationId;
}

/// The state of sync, without the server's address or the account.
class ReportSync {
  ReportSync({
    required this.connected,
    String? state,
    this.sinceSuccess,
    this.pending,
    this.needAttention,
    this.stages = const [],
  }) : state = ReportValue.id(state);

  /// Whether the app is set up to sync with a server at all.
  final bool connected;
  final String? state;
  final Duration? sinceSuccess;
  final int? pending;
  final int? needAttention;
  final List<ReportSyncStage> stages;
}

/// A feature that starts after the app opens and may fail on its own.
class ReportCapability {
  ReportCapability({
    required String id,
    required this.phase,
    String? failureType,
  }) : id = ReportValue.id(id) ?? 'unknown',
       failureType = ReportValue.typeName(failureType);

  final String id;

  /// `initializing`, `ready` or `degraded`.
  final String phase;
  final String? failureType;
}

/// Everything a problem report says, as typed facts.
///
/// Each section may be null when it could not be read; the report then says
/// so instead of failing. [toText] is the only way out, and the screen shows
/// that exact text before anything is shared.
class DiagnosticReport {
  const DiagnosticReport({
    required this.createdAt,
    this.app,
    this.device,
    this.permissions,
    this.data,
    this.sync,
    this.capabilities,
    this.lastStop,
    this.events = const [],
  });

  static const format = 'simpastil-report-v1';

  final DateTime createdAt;
  final ReportApp? app;
  final ReportDevice? device;
  final ReportPermissions? permissions;
  final ReportData? data;
  final ReportSync? sync;
  final List<ReportCapability>? capabilities;

  /// How Android says the previous run ended, such as `EXIT_CRASH`.
  final String? lastStop;
  final List<DiagnosticEvent> events;

  /// `simpastil-report-20261018-14.txt`: the date and hour, never the minute.
  String get fileName {
    String two(int n) => n.toString().padLeft(2, '0');
    final utc = createdAt.toUtc();
    return 'simpastil-report-${utc.year}${two(utc.month)}${two(utc.day)}-'
        '${two(utc.hour)}.txt';
  }

  String toText() {
    const unavailable = ReportValue.unavailable;
    final out = StringBuffer()
      ..writeln('Simpastil problem report')
      ..writeln('format: $format')
      ..writeln('created: ${ReportValue.hour(createdAt)}')
      ..writeln(
        'privacy: no names, medicines, doses, notes, server address, '
        'account or sign-in details are in this file',
      );

    void section(String name, List<String>? lines) {
      out
        ..writeln()
        ..writeln('[$name]');
      if (lines == null) {
        out.writeln('state: $unavailable');
        return;
      }
      lines.forEach(out.writeln);
    }

    String line(String key, String? value) => '$key: ${value ?? unavailable}';

    final app = this.app;
    section(
      'app',
      app == null
          ? null
          : [
              line('version', app.version),
              line('build', app.build),
              line('database', app.database),
              line('language', app.language),
            ],
    );

    final device = this.device;
    section(
      'device',
      device == null
          ? null
          : [
              line('android', device.androidRelease),
              line('sdk', device.sdk),
              line('maker', device.maker),
              line('model', device.model),
              line('screen', device.screen?.wireName),
            ],
    );

    final permissions = this.permissions;
    section(
      'permissions',
      permissions == null
          ? null
          : [
              line('notifications', permissions.notifications?.wireName),
              line('exact-alarms', permissions.exactAlarms?.wireName),
              line(
                'battery-unrestricted',
                permissions.batteryUnrestricted?.wireName,
              ),
            ],
    );

    final data = this.data;
    section(
      'data',
      data == null
          ? null
          : [
              line('profiles', ReportValue.count(data.profiles)),
              line('medicines', ReportValue.count(data.medicines)),
              line('schedules', ReportValue.count(data.schedules)),
              line('dose-records', ReportValue.count(data.doseRecords)),
              line('reminders', ReportValue.count(data.scheduledReminders)),
            ],
    );

    final sync = this.sync;
    section(
      'sync',
      sync == null
          ? null
          : [
              line('connected', sync.connected ? 'yes' : 'no'),
              if (sync.connected) ...[
                line('status', sync.state),
                line('last-success', ReportValue.age(sync.sinceSuccess)),
                line('pending', ReportValue.count(sync.pending)),
                line('needs-attention', ReportValue.count(sync.needAttention)),
                for (final stage in sync.stages) _stageLine(stage),
              ],
            ],
    );

    final capabilities = this.capabilities;
    section(
      'features',
      capabilities == null
          ? null
          : [
              if (capabilities.isEmpty) 'state: none-reported',
              for (final item in capabilities)
                'feature: ${item.id} ${item.phase}'
                    '${item.failureType == null ? '' : ' type=${item.failureType}'}',
            ],
    );

    section('last-stop', [
      line('reason', ReportValue.code(lastStop) ?? 'none-recorded'),
    ]);

    section('events', [
      if (events.isEmpty) 'state: none-recorded',
      for (final event in events) 'event: ${_eventText(event)}',
    ]);
    return out.toString();
  }

  static String _stageLine(ReportSyncStage stage) {
    final parts = <String>[
      'stage: ${stage.id}',
      stage.status,
      if (stage.code != null) 'code=${stage.code}',
      if (stage.httpStatus != null) 'http=${stage.httpStatus}',
      if (stage.retries != null) 'retries=${stage.retries}',
      if (stage.took != null) 'took=${ReportValue.took(stage.took)}',
      if (stage.correlationId != null) 'corr=${stage.correlationId}',
    ];
    return parts.join(' ');
  }

  static String _eventText(DiagnosticEvent event) {
    final parts = <String>[
      ReportValue.hour(event.at),
      event.kind.wireName,
      'source=${event.source.wireName}',
      if (event.component != null) 'component=${event.component!.wireName}',
      if (event.errorType != null) 'type=${event.errorType}',
      if (event.code != null) 'code=${event.code}',
      if (event.library != null) 'lib=${event.library}',
      if (event.where.isNotEmpty) 'at=${event.where.join(',')}',
    ];
    return parts.join(' ');
  }
}
