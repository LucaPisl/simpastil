import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/move/local_care_removal.dart';
import '../db/database.dart';
import '../storage/preference_keys.dart';

/// Removes everything this phone holds for one deleted account: its people,
/// medications, routines, doses and stock, anything waiting to be sent, the
/// sync positions, the settings mirror, the reminders and the account's row.
///
/// Care kept only on this phone (the local workspace) is never touched; it
/// belongs to a different owner. The deletion runs in one transaction, so a
/// failure leaves the account whole rather than half removed.
///
/// Returns how many unsent changes were discarded, so the screen can say that
/// they did not reach the server.
Future<int> removeAccountData(
  AppDatabase db, {
  required String accountUserId,
}) async {
  return db.transaction(() async {
    final workspace = await (db.select(
      db.careWorkspaces,
    )..where((w) => w.ownerUserId.equals(accountUserId))).getSingleOrNull();
    final workspaceId = workspace?.id;

    final unsent =
        await (db.select(db.pendingOperations)..where(
              (o) =>
                  o.userId.equals(accountUserId) &
                  o.state.isIn(const [
                    'queued',
                    'sending',
                    'conflict',
                    'failedRetryable',
                    'blocked',
                  ]),
            ))
            .get();
    final pendingSettings = await (db.select(
      db.pendingAccountSettings,
    )..where((s) => s.userId.equals(accountUserId))).get();

    final profiles = await (db.select(
      db.profiles,
    )..where((p) => p.userId.equals(accountUserId))).get();
    if (workspaceId != null && profiles.isNotEmpty) {
      await removeLocalCare(
        db,
        localWorkspaceId: workspaceId,
        localOwnerId: accountUserId,
        profileIds: {for (final p in profiles) p.id},
      );
    }

    // History that no longer hangs off a medication (its pill was deleted).
    final events = await (db.select(
      db.occurrenceEvents,
    )..where((e) => e.userId.equals(accountUserId))).get();
    if (events.isNotEmpty) {
      await (db.delete(
        db.careEventDetails,
      )..where((d) => d.eventId.isIn({for (final e in events) e.id}))).go();
    }
    await (db.delete(
      db.inventoryEvents,
    )..where((i) => i.userId.equals(accountUserId))).go();
    // Reversals point at earlier events, so clear the pointers first.
    await (db.update(db.occurrenceEvents)
          ..where((e) => e.userId.equals(accountUserId)))
        .write(const OccurrenceEventsCompanion(reversesEventId: Value(null)));
    await (db.delete(
      db.occurrenceEvents,
    )..where((e) => e.userId.equals(accountUserId))).go();
    await (db.update(
      db.medicationOccurrences,
    )..where((o) => o.userId.equals(accountUserId))).write(
      const MedicationOccurrencesCompanion(
        supersededByOccurrenceId: Value(null),
      ),
    );
    await (db.delete(
      db.medicationOccurrences,
    )..where((o) => o.userId.equals(accountUserId))).go();

    if (workspaceId != null) {
      await (db.delete(
        db.effectSettlements,
      )..where((s) => s.workspaceId.equals(workspaceId))).go();
    }
    await (db.delete(
      db.pendingOperations,
    )..where((o) => o.userId.equals(accountUserId))).go();
    await (db.delete(
      db.syncStagingRuns,
    )..where((r) => r.userId.equals(accountUserId))).go();
    await (db.delete(
      db.syncComponentStates,
    )..where((s) => s.userId.equals(accountUserId))).go();
    await (db.delete(
      db.migrationIssues,
    )..where((i) => i.userId.equals(accountUserId))).go();
    await (db.delete(
      db.accountSettingValues,
    )..where((s) => s.userId.equals(accountUserId))).go();
    await (db.delete(
      db.pendingAccountSettings,
    )..where((s) => s.userId.equals(accountUserId))).go();
    await (db.delete(
      db.refreshTokens,
    )..where((t) => t.userId.equals(accountUserId))).go();

    if (workspaceId != null) {
      final receipts = await (db.select(
        db.importReceipts,
      )..where((r) => r.workspaceId.equals(workspaceId))).get();
      final receiptIds = {for (final r in receipts) r.id};
      if (receiptIds.isNotEmpty) {
        await (db.delete(
          db.importConflicts,
        )..where((c) => c.receiptId.isIn(receiptIds))).go();
        await (db.delete(
          db.importEvidence,
        )..where((e) => e.receiptId.isIn(receiptIds))).go();
        await (db.delete(
          db.deviceRestoreIntents,
        )..where((i) => i.receiptId.isIn(receiptIds))).go();
        await (db.delete(
          db.importReceipts,
        )..where((r) => r.id.isIn(receiptIds))).go();
      }
      await (db.delete(
        db.deviceReminderSettings,
      )..where((s) => s.workspaceId.equals(workspaceId))).go();
      await (db.delete(
        db.setupDrafts,
      )..where((d) => d.workspaceId.equals(workspaceId))).go();
      await (db.delete(
        db.reviewedStockBalances,
      )..where((b) => b.workspaceId.equals(workspaceId))).go();
      await (db.delete(
        db.localRoutines,
      )..where((r) => r.workspaceId.equals(workspaceId))).go();
      await (db.update(
        db.workspaceDeviceStates,
      )..where((s) => s.selectedWorkspaceId.equals(workspaceId))).write(
        const WorkspaceDeviceStatesCompanion(selectedWorkspaceId: Value(null)),
      );
      await (db.delete(
        db.workspaceGrants,
      )..where((g) => g.workspaceId.equals(workspaceId))).go();
      await (db.delete(
        db.workspaceAuthors,
      )..where((a) => a.workspaceId.equals(workspaceId))).go();
      await (db.delete(
        db.careWorkspaces,
      )..where((w) => w.id.equals(workspaceId))).go();
    }
    await (db.delete(db.users)..where((u) => u.id.equals(accountUserId))).go();

    return unsent.length + pendingSettings.length;
  });
}

/// Whether [key] ends in [accountUserId] after a separator: `name_<id>`,
/// `name.<id>`. An empty id matches nothing.
bool _endsWithAccount(String key, String accountUserId) {
  if (accountUserId.isEmpty) return false;
  final at = key.length - accountUserId.length;
  return at > 0 &&
      key.endsWith(accountUserId) &&
      !RegExp('[A-Za-z0-9]').hasMatch(key[at - 1]);
}

/// Preference keys that end in this account's id. Every one is Dart-only
/// (the widget contract reads fixed names), so removing them is safe. They
/// are matched by shape so a setting added later is swept too; that includes
/// the account's own chosen-keys list. An empty id removes nothing.
Future<void> removeAccountPreferences(
  SharedPreferences preferences, {
  required String accountUserId,
}) async {
  if (accountUserId.isEmpty) return;
  for (final key in preferences.getKeys().toList()) {
    if (_endsWithAccount(key, accountUserId)) await preferences.remove(key);
  }
  // The device-wide list an earlier build kept: trim this account's keys by
  // the same rule.
  final chosen = preferences.getStringList(kChosenSettingKeysKey);
  if (chosen != null) {
    final kept = [
      for (final key in chosen)
        if (!_endsWithAccount(key, accountUserId)) key,
    ];
    if (kept.length != chosen.length) {
      await preferences.setStringList(kChosenSettingKeysKey, kept);
    }
  }
  // A device-wide setting the removed account chose stays on screen, so it
  // becomes a choice made with nobody signed in: the next account to sign in
  // adopts it, and the removed id is not kept.
  for (final key in deviceWideAccountSettingPreferenceKeys) {
    final chooserKey = settingChooserPreferenceKey(key);
    if (preferences.getString(chooserKey) == accountUserId) {
      await preferences.setString(chooserKey, signedOutSettingChooser);
    }
  }
  if (preferences.getString('current_user_id') == accountUserId) {
    await preferences.remove('current_user_id');
  }
}

/// Signs the phone out of a deleted account, then removes what it held.
///
/// Sign-out comes first: it stops sync, cancels reminders and clears the
/// installation key, so nothing writes while the rows go. Each later step is
/// tried even if an earlier one failed, because a half-clean phone is better
/// than one that keeps a deleted account's data. Returns the count of
/// discarded unsent changes, or 0 when that could not be told.
Future<int> completeAccountDeletion({
  required Future<void> Function() signOut,
  required AppDatabase db,
  required SharedPreferences prefs,
  required String accountUserId,
}) async {
  try {
    await signOut();
  } on Object {
    // The server no longer knows this session; local cleanup still proceeds.
  }
  var discarded = 0;
  try {
    discarded = await removeAccountData(db, accountUserId: accountUserId);
  } on Object {
    // Left for the next start; the account is already gone on the server.
  }
  try {
    await removeAccountPreferences(prefs, accountUserId: accountUserId);
  } on Object {
    // Preferences hold no medication data; a leftover is harmless.
  }
  return discarded;
}
