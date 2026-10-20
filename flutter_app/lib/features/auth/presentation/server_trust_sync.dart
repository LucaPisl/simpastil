import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sync/auto_sync_service.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../profiles/profile_provider.dart';

/// Syncs right after the person trusted the server again, so the Sync screen
/// does not keep saying the server was unreachable or its key changed.
///
/// It uses the same entry point as the Sync screen's "Sync now". A device with
/// no signed-in account has nothing to sync, and a failed sync is reported by
/// the sync status rather than here.
void requestSyncAfterServerTrust(WidgetRef ref) {
  unawaited(() async {
    try {
      // Read before the first await: the calling screen may close right away.
      final service = ref.read(autoSyncServiceProvider);
      final access = ref.read(workspaceAccessRepositoryProvider);
      final userId = ref.read(currentUserIdProvider);
      if (await access.currentNetworkCapability() == null) return;
      await service.syncNow(userId);
    } on Object {
      // The sync status reports a failure.
    }
  }());
}
