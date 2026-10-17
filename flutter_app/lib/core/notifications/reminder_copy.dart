import '../../l10n/app_localizations.dart';

/// The words on one reminder notification.
///
/// Copy is a pure function of a single occurrence (its name, amount and
/// follow-up offset) and the privacy choice. The reconciler rebuilds the
/// expected copy for one occurrence at a time and compares it with what the
/// platform reports, so copy must never depend on other doses.
class ReminderCopy {
  const ReminderCopy({required this.title, required this.body});

  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is ReminderCopy && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  @override
  String toString() => 'ReminderCopy($title / $body)';
}

/// Copy for a scheduled dose reminder or one of its follow-ups.
///
/// With [fullDetails] off nothing about the medication is said: no name, no
/// amount and no hint that this is a follow-up.
ReminderCopy doseReminderCopy(
  AppLocalizations l, {
  required bool fullDetails,
  required String pillName,
  String? dosage,
  int followUpMinutes = 0,
}) {
  if (!fullDetails) return privateReminderCopy(l);
  final amount = dosage?.trim() ?? '';
  final followUp = followUpMinutes > 0;
  if (followUp) {
    return ReminderCopy(
      title: l.r6_notifStillTitle(pillName),
      body: amount.isEmpty
          ? l.r6_notifStillNoDoseBody
          : l.r6_notifStillBody(amount),
    );
  }
  return ReminderCopy(
    title: l.core_notifTitle(pillName),
    body: amount.isEmpty ? l.r6_notifNoDoseBody : l.r6_notifDoseBody(amount),
  );
}

/// Copy for a reminder the person snoozed from the notification.
ReminderCopy snoozedReminderCopy(
  AppLocalizations l, {
  required bool fullDetails,
  required String pillName,
}) => fullDetails
    ? ReminderCopy(
        title: l.core_notifTitle(pillName),
        body: l.core_notifSnoozed,
      )
    : privateReminderCopy(l);

/// Generic copy that only asks the person to open the app.
ReminderCopy privateReminderCopy(AppLocalizations l) => ReminderCopy(
  title: l.core_notifPrivateTitle,
  body: l.core_notifPrivateBody,
);

/// Copy for the low-stock alert. Private mode says nothing about the
/// medication or its count, exactly like a private dose reminder.
ReminderCopy lowStockReminderCopy(
  AppLocalizations l, {
  required bool fullDetails,
  required String pillName,
  required int dosesLeft,
}) => fullDetails
    ? ReminderCopy(
        title: l.r8_lowStockTitle(pillName),
        body: l.r8_lowStockBody(dosesLeft),
      )
    : privateReminderCopy(l);
