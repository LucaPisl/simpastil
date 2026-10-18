import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/diagnostics/report/diagnostic_report.dart';
import 'package:simpastil/features/report/report_links.dart';

void main() {
  final created = DateTime.utc(2026, 10, 18, 14);

  test('the issue link starts the bug form with release and device filled', () {
    final uri = reportIssueUri(
      DiagnosticReport(
        createdAt: created,
        app: ReportApp(version: '1.0.0', build: 3),
        device: ReportDevice(
          androidRelease: '14',
          maker: 'samsung',
          model: 'SM-S938B',
        ),
      ),
    );
    expect(uri.scheme, 'https');
    expect(uri.host, 'github.com');
    expect(uri.path, '/LucaPisl/simpastil/issues/new');
    expect(uri.queryParameters, {
      'template': 'bug_report.yml',
      'labels': 'bug',
      'version': '1.0.0 (build 3)',
      'device': 'samsung SM-S938B, Android 14',
    });
    expect(uri.toString().length, lessThan(300));
  });

  test('every field the link fills exists in the committed issue form', () {
    final form = File(
      '../.github/ISSUE_TEMPLATE/$reportIssueTemplate',
    ).readAsStringSync();
    final uri = reportIssueUri(
      DiagnosticReport(
        createdAt: created,
        app: ReportApp(version: '1.0.0', build: 3),
        device: ReportDevice(androidRelease: '14', model: 'SM-S938B'),
      ),
    );
    for (final key in uri.queryParameters.keys.where(
      (k) => k != 'template' && k != 'labels',
    )) {
      expect(form, contains('id: $key\n'), reason: 'form has no field "$key"');
    }
    expect(form, contains('labels: ["bug"]'));
  });

  test('facts the report could not read are left out, not guessed', () {
    final uri = reportIssueUri(DiagnosticReport(createdAt: created));
    expect(uri.queryParameters, {
      'template': 'bug_report.yml',
      'labels': 'bug',
    });
  });

  test('hostile text never reaches the link', () {
    final uri = reportIssueUri(
      DiagnosticReport(
        createdAt: created,
        app: ReportApp(version: 'luca@example.com'),
        device: ReportDevice(maker: 'https://sync.example.org', model: '<x>'),
      ),
    );
    expect(uri.toString(), isNot(contains('example')));
    expect(uri.queryParameters.containsKey('version'), isFalse);
  });

  test('the email subject names the release and stays in English', () {
    expect(
      reportEmailSubject(
        DiagnosticReport(
          createdAt: created,
          app: ReportApp(version: '1.0.0'),
        ),
      ),
      'Simpastil problem report (1.0.0)',
    );
    expect(
      reportEmailSubject(DiagnosticReport(createdAt: created)),
      'Simpastil problem report',
    );
    expect(reportEmailBody, contains('The report file is attached'));
  });
}
