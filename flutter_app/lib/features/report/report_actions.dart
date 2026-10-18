import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/diagnostics/report/diagnostic_report.dart';
import '../../core/diagnostics/report/report_channel.dart';
import 'report_links.dart';

/// What the person can do with a finished report. Every method answers with
/// what happened and never throws, so the screen can always say something.
class ReportActions {
  ReportActions({
    ReportChannel? channel,
    Future<bool> Function(Uri uri)? launch,
    Future<void> Function(String fileName, String content)? shareFile,
  }) : _channel = channel ?? ReportChannel(),
       _launch = launch ?? _launchExternally,
       _shareFile = shareFile ?? _shareThroughSystem;

  final ReportChannel _channel;
  final Future<bool> Function(Uri uri) _launch;
  final Future<void> Function(String fileName, String content) _shareFile;

  /// Writes the report straight into the Downloads folder.
  Future<ReportSaveResult> saveToDownloads(DiagnosticReport report) => _channel
      .saveToDownloads(fileName: report.fileName, content: report.toText());

  /// Opens the email app with the message written and the file attached.
  Future<ReportEmailStatus> emailMaintainer(
    DiagnosticReport report, {
    required String chooserTitle,
  }) => _channel.composeEmail(
    to: maintainerEmail,
    subject: reportEmailSubject(report),
    body: reportEmailBody,
    title: chooserTitle,
    fileName: report.fileName,
    content: report.toText(),
  );

  /// Opens the new-issue form on GitHub with the facts filled in.
  Future<bool> openGitHub(DiagnosticReport report) async {
    try {
      return await _launch(reportIssueUri(report));
    } on Object {
      return false;
    }
  }

  /// Hands the file to any app the person picks.
  Future<bool> shareWithApp(DiagnosticReport report) async {
    try {
      await _shareFile(report.fileName, report.toText());
      return true;
    } on Object {
      return false;
    }
  }

  static Future<bool> _launchExternally(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  static Future<void> _shareThroughSystem(
    String fileName,
    String content,
  ) async {
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}reports',
    );
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(content, flush: true);
    await Share.shareXFiles([XFile(file.path, mimeType: 'text/plain')]);
  }
}
