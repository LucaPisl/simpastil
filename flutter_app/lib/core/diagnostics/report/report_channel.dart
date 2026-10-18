import 'package:flutter/services.dart';

import '../process_exit.dart';

enum ReportSaveStatus {
  /// The file is in the Downloads folder.
  saved,

  /// This Android version cannot save there without a storage permission.
  unsupported,
  failed,
}

class ReportSaveResult {
  const ReportSaveResult(this.status, {this.name});

  final ReportSaveStatus status;

  /// The name Android gave the file. It may differ from the one asked for.
  final String? name;
}

enum ReportEmailStatus { opened, noEmailApp, failed }

/// The Android helpers behind the problem report: save to Downloads, hand the
/// file to an email app, and how the previous run ended.
///
/// No call throws. A platform that has no such helper (tests, other systems)
/// answers as if the action failed.
class ReportChannel {
  ReportChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.simpastil/report';

  final MethodChannel _channel;

  Future<ReportSaveResult> saveToDownloads({
    required String fileName,
    required String content,
  }) async {
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>(
        'saveToDownloads',
        {'fileName': fileName, 'content': content},
      );
      return switch (reply?['status']) {
        'saved' => ReportSaveResult(
          ReportSaveStatus.saved,
          name: reply?['name'] is String ? reply!['name']! as String : fileName,
        ),
        'unsupported' => const ReportSaveResult(ReportSaveStatus.unsupported),
        _ => const ReportSaveResult(ReportSaveStatus.failed),
      };
    } on Object {
      return const ReportSaveResult(ReportSaveStatus.failed);
    }
  }

  Future<ReportEmailStatus> composeEmail({
    required String to,
    required String subject,
    required String body,
    required String title,
    required String fileName,
    required String content,
  }) async {
    try {
      final reply = await _channel.invokeMethod<String>('composeEmail', {
        'to': to,
        'subject': subject,
        'body': body,
        'title': title,
        'fileName': fileName,
        'content': content,
      });
      return switch (reply) {
        'opened' => ReportEmailStatus.opened,
        'no_app' => ReportEmailStatus.noEmailApp,
        _ => ReportEmailStatus.failed,
      };
    } on Object {
      return ReportEmailStatus.failed;
    }
  }

  /// How Android recorded the end of the previous run; null when it did not
  /// (Android 10 and older, or no record).
  Future<ProcessExit?> lastExit() async {
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>('lastExit');
      final reason = reply?['reason'];
      final timestamp = reply?['timestamp'];
      if (reason is! String || timestamp is! int) return null;
      return ProcessExit(
        reason: reason,
        at: DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
      );
    } on Object {
      return null;
    }
  }
}
