import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/projections/projection_reconciler.dart';
import '../../../core/projections/reminder_reconcile_runner.dart';
import '../../../core/storage/shared_preferences_provider.dart';
import '../../../l10n/app_localizations.dart';
import 'settings_overview.dart';

/// Asks for confirmation, resets every reminder on this phone, and says how it
/// went. Shared by Settings > Reminders and the Fix sync problems screen.
Future<void> confirmAndResetReminders(
  BuildContext context,
  WidgetRef ref,
) async {
  final l = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final locale = Localizations.localeOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l.reminders_resetTitle),
      content: Text(l.reminders_resetConfirmBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l.shared_cancel),
        ),
        FilledButton(
          key: const ValueKey('reset-reminders-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l.reminders_resetAction),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final ReminderResetResult result;
  try {
    result = await ref.read(reminderResetProvider)(locale);
  } on Object {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.reminders_resetFailed)));
    return;
  }
  final text = result.succeeded
      ? l.reminders_resetDone(result.scheduled)
      : result.failure == ReminderResetFailure.permission
      ? l.reminders_resetNeedsPermission
      : result.failure == ReminderResetFailure.registry
      ? l.reminders_resetRegistryUnreadable
      : result.restoring
      ? l.reminders_resetRestoring
      : l.reminders_resetFailed;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// The last reminder audit's counts, for the Repair group. Counts only.
final reminderAuditReportProvider =
    FutureProvider.autoDispose<ReminderAuditReport?>((ref) async {
      final preferences = ref.watch(sharedPreferencesProvider);
      await preferences.reload();
      final raw = preferences.getString(reminderAuditReportPreferenceKey);
      if (raw == null) return null;
      try {
        return ReminderAuditReport.fromJson(jsonDecode(raw));
      } on FormatException {
        return null;
      }
    });

class ResetRemindersRow extends ConsumerWidget {
  const ResetRemindersRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final report = ref.watch(reminderAuditReportProvider).valueOrNull;
    var subtitle = l.reminders_resetHint;
    if (report != null) {
      final material = MaterialLocalizations.of(context);
      final local = report.at.toLocal();
      final when =
          '${material.formatShortDate(local)} '
          '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
      final status = report.ran
          ? l.reminders_auditStatus(when, report.cancelledTotal)
          : l.reminders_auditDeferred(when);
      final partial = report.skippedWorkspaces + report.heldOutWorkspaces > 0
          ? l.reminders_auditPartial
          : '';
      subtitle = '$subtitle\n$status$partial';
    }
    return SettingsNavigationRow(
      icon: Icons.restart_alt_rounded,
      title: l.reminders_resetTitle,
      subtitle: subtitle,
      onTap: () => confirmAndResetReminders(context, ref),
    );
  }
}
