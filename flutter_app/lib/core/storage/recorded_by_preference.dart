import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import '../workspace/workspace_context.dart';
import 'shared_preferences_provider.dart';

/// Whose name is stamped as the author of a newly recorded dose.
///
/// Stored by [RecordedByMode.name]; an unknown stored name reads as
/// [primaryProfile], so an older build that meets a newer value still works.
enum RecordedByMode {
  primaryProfile,
  custom,
  personTakingIt;

  static RecordedByMode parse(Object? stored) {
    for (final mode in values) {
      if (mode.name == stored) return mode;
    }
    return primaryProfile;
  }
}

/// Dart-only, device-local preferences scoped per owner user. They are
/// deliberately not in `BackupInventory.preferenceAllowed` (the custom name is
/// personal) and are never part of the native widget contract.
String recordedByModePreferenceKey(String userId) => 'recorded_by_mode_$userId';
String recordedByNamePreferenceKey(String userId) => 'recorded_by_name_$userId';

class RecordedBySetting {
  const RecordedBySetting({
    this.mode = RecordedByMode.primaryProfile,
    this.customName = '',
  });
  final RecordedByMode mode;
  final String customName;

  static RecordedBySetting read(SharedPreferences? prefs, String userId) {
    if (prefs == null) return const RecordedBySetting();
    try {
      final name = prefs.get(recordedByNamePreferenceKey(userId));
      return RecordedBySetting(
        mode: RecordedByMode.parse(
          prefs.get(recordedByModePreferenceKey(userId)),
        ),
        customName: name is String ? name : '',
      );
    } on Object {
      return const RecordedBySetting();
    }
  }
}

String? _clean(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Pure choice of the author name. The chosen source wins when it has a name;
/// otherwise the workspace author's own name, then null.
String? chooseRecordedByName({
  required RecordedBySetting setting,
  String? primaryProfileName,
  String? personTakingItName,
  String? authorDisplayName,
}) {
  final chosen = switch (setting.mode) {
    RecordedByMode.primaryProfile => _clean(primaryProfileName),
    RecordedByMode.custom => _clean(setting.customName),
    RecordedByMode.personTakingIt => _clean(personTakingItName),
  };
  return chosen ?? _clean(authorDisplayName);
}

/// Resolves the name to store on a new care event, at record time. Called
/// inside the recording transaction so it reads the same protected state.
Future<String?> resolveRecordedByName({
  required AppDatabase db,
  required WorkspaceContext context,
  required String? patientProfileId,
  required String? authorDisplayName,
}) async {
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
    // A background isolate may hold a snapshot older than the app's last save.
    await prefs.reload();
  } on Object {
    prefs = null;
  }
  final setting = RecordedBySetting.read(prefs, context.ownerUserId);

  Future<String?> profileName(String? id) async {
    if (id == null) return null;
    final row =
        await (db.select(db.profiles)..where(
              (p) =>
                  p.id.equals(id) &
                  p.userId.equals(context.ownerUserId) &
                  p.isDeleted.equals(false),
            ))
            .getSingleOrNull();
    return row?.name;
  }

  String? primaryName;
  if (setting.mode == RecordedByMode.primaryProfile) {
    final workspace = await (db.select(
      db.careWorkspaces,
    )..where((w) => w.id.equals(context.workspaceId))).getSingleOrNull();
    primaryName = await profileName(workspace?.selectedProfileId);
    if (primaryName == null) {
      // Same fallback as the primary-profile setting: first person by name.
      final first =
          await (db.select(db.profiles)
                ..where(
                  (p) =>
                      p.userId.equals(context.ownerUserId) &
                      p.isDeleted.equals(false),
                )
                ..orderBy([(p) => OrderingTerm.asc(p.name)])
                ..limit(1))
              .getSingleOrNull();
      primaryName = first?.name;
    }
  }
  return chooseRecordedByName(
    setting: setting,
    primaryProfileName: primaryName,
    personTakingItName: setting.mode == RecordedByMode.personTakingIt
        ? await profileName(patientProfileId)
        : null,
    authorDisplayName: authorDisplayName,
  );
}

class RecordedByPersistenceFailure implements Exception {
  const RecordedByPersistenceFailure();
}

class RecordedByNotifier extends Notifier<RecordedBySetting> {
  RecordedByNotifier(this.arg);

  /// The signed-in user the setting belongs to.
  final String arg;

  SharedPreferences? _preferences;

  @override
  RecordedBySetting build() {
    try {
      _preferences = ref.watch(sharedPreferencesProvider);
    } on Object {
      _preferences = null;
    }
    return RecordedBySetting.read(_preferences, arg);
  }

  Future<void> apply(RecordedBySetting next) async {
    final preferences = _preferences;
    if (preferences == null) throw const RecordedByPersistenceFailure();
    final name = next.customName.trim();
    final savedName = await preferences.setString(
      recordedByNamePreferenceKey(arg),
      name,
    );
    final savedMode = await preferences.setString(
      recordedByModePreferenceKey(arg),
      next.mode.name,
    );
    if (!savedName || !savedMode) throw const RecordedByPersistenceFailure();
    state = RecordedBySetting(mode: next.mode, customName: name);
  }
}

final recordedByProvider =
    NotifierProvider.family<RecordedByNotifier, RecordedBySetting, String>(
      RecordedByNotifier.new,
    );
