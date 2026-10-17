/// Versioned Android notification channel for dose reminders.
///
/// Android ignores importance and sound changes on a channel that already
/// exists, so changing either requires a new channel id. Bump
/// [kReminderChannelRevision] only when a channel setting actually changes;
/// every earlier revision's id is then retired and deleted on startup, and
/// pending reminders are rescheduled onto the new channel by the reconciler
/// (it compares the revision stored in its registry).
///
/// Revision 1 keeps the original unsuffixed id so existing installs are
/// untouched until a bump.
const kReminderChannelBaseId = 'dose_reminders';
const kReminderChannelRevision = 1;

String reminderChannelIdForRevision(int revision) {
  if (revision < 1) throw ArgumentError.value(revision, 'revision');
  return revision == 1
      ? kReminderChannelBaseId
      : '${kReminderChannelBaseId}_v$revision';
}

/// The id new notifications are published on.
String currentReminderChannelId([int revision = kReminderChannelRevision]) =>
    reminderChannelIdForRevision(revision);

/// Every id of an earlier revision; these channels are deleted.
List<String> retiredReminderChannelIds([
  int revision = kReminderChannelRevision,
]) => [for (var r = 1; r < revision; r++) reminderChannelIdForRevision(r)];

/// True for the current id or one of the retired ids of this app.
bool isKnownReminderChannelId(
  String id, [
  int revision = kReminderChannelRevision,
]) =>
    id == currentReminderChannelId(revision) ||
    retiredReminderChannelIds(revision).contains(id);
