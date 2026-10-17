import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' show simpastilClientBuild;
import '../../core/server/server_config_notifier.dart';
import '../../core/storage/shared_preferences_provider.dart';
import 'data/github_release_check.dart';
import 'data/update_hint.dart';

/// Dart-only, device-local: the newest build whose card was closed.
const updateDismissedBuildKey = 'update_dismissed_build';

class UpdateStatus {
  const UpdateStatus({required this.build, required this.releaseUrl});
  final int build;
  final Uri releaseUrl;

  /// The version named by the release page (`.../tag/v1.2.0`), when it reads
  /// as one.
  String? get version {
    final segments = releaseUrl.pathSegments;
    if (segments.isEmpty) return null;
    final last = segments.last;
    final candidate = last.startsWith('v') ? last.substring(1) : last;
    return RegExp(r'^\d+\.\d+\.\d+$').hasMatch(candidate) ? candidate : null;
  }
}

/// The release this device should be told about, or null. A server-sourced
/// answer counts only while a server is configured, a GitHub-sourced one only
/// while none is. "Update required" wins over this soft notice because
/// [UpdateHint.recordFromServer] clears the hint whenever the server says the
/// app must update (the overview must not subscribe to the sync status).
class UpdateStatusNotifier extends AsyncNotifier<UpdateStatus?> {
  @override
  Future<UpdateStatus?> build() async {
    void reread() => ref.invalidateSelf();
    UpdateHint.changes.addListener(reread);
    ref.onDispose(() => UpdateHint.changes.removeListener(reread));

    final prefs = ref.watch(sharedPreferencesProvider);
    final server = ref.watch(serverConfigProvider);
    final build = prefs.getInt(UpdateHint.latestBuildKey);
    final url = prefs.getString(UpdateHint.releaseUrlKey);
    final source = prefs.getString(UpdateHint.sourceKey);
    if (build == null || url == null || build <= simpastilClientBuild) {
      return null;
    }
    if (!isValidReleaseUrl(url)) return null;
    final dismissed = prefs.getInt(updateDismissedBuildKey);
    if (dismissed != null && dismissed >= build) return null;
    if (source == UpdateHint.sourceServer && server == null) return null;
    if (source == UpdateHint.sourceGitHub) {
      if (server != null) return null;
      if (prefs.getBool(updateCheckEnabledKey) == false) return null;
    }
    if (source != UpdateHint.sourceServer &&
        source != UpdateHint.sourceGitHub) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    return UpdateStatus(build: build, releaseUrl: uri);
  }

  /// Hides the current release until a newer build is announced.
  Future<void> dismiss() async {
    final current = state.valueOrNull;
    if (current == null) return;
    try {
      await ref
          .read(sharedPreferencesProvider)
          .setInt(updateDismissedBuildKey, current.build);
    } on Object {
      // Still hide it for this session.
    }
    state = const AsyncData(null);
  }
}

final updateStatusProvider =
    AsyncNotifierProvider<UpdateStatusNotifier, UpdateStatus?>(
      UpdateStatusNotifier.new,
    );
