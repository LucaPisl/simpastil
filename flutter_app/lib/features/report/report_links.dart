import '../../core/diagnostics/report/diagnostic_report.dart';

/// Where reports go. One place, so the issue template, the email and the
/// documentation stay in step.
const reportRepository = 'LucaPisl/simpastil';

/// The address the "Email the maintainer" option writes to.
const maintainerEmail = 'simpastil@protonmail.com';

/// The GitHub issue form the app opens ready-filled
/// (`.github/ISSUE_TEMPLATE/bug_report.yml`).
const reportIssueTemplate = 'bug_report.yml';

/// The new-issue page with as much as possible already filled in.
///
/// A link cannot carry a file, so only short facts that are already in the
/// report go here (release and device); the person attaches the saved file.
/// The field names are the `id`s of the issue form's inputs. Values that the
/// report could not read are left out rather than filled with a placeholder.
Uri reportIssueUri(DiagnosticReport report) {
  final app = report.app;
  final device = report.device;
  final version = app?.version == null
      ? null
      : app!.build == null
      ? app.version
      : '${app.version} (build ${app.build})';
  final hardware = [
    if (device?.maker != null) device!.maker,
    if (device?.model != null) device!.model,
  ].join(' ');
  final android = device?.androidRelease == null
      ? null
      : 'Android ${device!.androidRelease}';
  final deviceLine = [if (hardware.isNotEmpty) hardware, ?android].join(', ');
  return Uri.https('github.com', '/$reportRepository/issues/new', {
    'template': reportIssueTemplate,
    'labels': 'bug',
    'version': ?version,
    if (deviceLine.isNotEmpty) 'device': deviceLine,
  });
}

/// The email subject: short, and enough to tell reports apart.
String reportEmailSubject(DiagnosticReport report) {
  final version = report.app?.version;
  return version == null
      ? 'Simpastil problem report'
      : 'Simpastil problem report ($version)';
}

/// The email body. It goes to the maintainer, so it is always in English.
const reportEmailBody = '''
Hello,

What happened (please describe in a few lines):


What I was doing just before:


The report file is attached. It holds technical details only.
''';
