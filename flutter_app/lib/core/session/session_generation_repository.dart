import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/shared_preferences_provider.dart';
import '../storage/preference_keys.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../workspace/workspace_provider.dart';

typedef SessionIdentity = (String, int);

const sessionGenerationPreferenceKey = kSessionGenerationKey;
const activeSessionUserIdPreferenceKey = kActiveUserIdKey;

/// Persists session ownership separately from credentials, which are cleared
/// on logout. A generation change makes work from an earlier session stale.
class SessionGenerationRepository {
  SessionGenerationRepository(this._prefs, {this.access});

  final SharedPreferences _prefs;
  final WorkspaceAccessRepository? access;
  Future<void> _writeQueue = Future<void>.value();

  Future<int> advanceTo(String? userId) {
    final result = Completer<int>();
    _writeQueue = _writeQueue
        .then((_) async {
          final protected = access;
          int generation;
          if (protected == null) {
            generation = await currentGeneration() + 1;
          } else if (userId == null) {
            // Auth owns durable revocation. Late runtime teardown must never
            // revoke a newer session that another engine has already published.
            generation =
                (await protected.workspaces.deviceState()).networkEpoch;
          } else {
            final capability = await protected.currentNetworkCapability();
            if (capability?.ownerId != userId) {
              throw const WorkspaceAccessFailure(
                WorkspaceAccessFailureCode.staleGrant,
              );
            }
            generation = capability!.generation;
          }
          // Clear the old owner first so a background isolate cannot observe
          // the prior account paired with the new generation mid-transition.
          await _prefs.remove(activeSessionUserIdPreferenceKey);
          final saved = await _prefs.setInt(
            sessionGenerationPreferenceKey,
            generation,
          );
          if (!saved) throw StateError('Could not persist session generation');

          if (userId != null) {
            final ownerSaved = await _prefs.setString(
              activeSessionUserIdPreferenceKey,
              userId,
            );
            if (!ownerSaved) {
              throw StateError('Could not persist session owner');
            }
          }
          result.complete(generation);
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (!result.isCompleted) result.completeError(error, stackTrace);
        });
    return result.future;
  }

  Future<int> currentGeneration() async => access == null
      ? _prefs.getInt(sessionGenerationPreferenceKey) ?? 0
      : (await access!.workspaces.deviceState()).networkEpoch;

  Future<SessionIdentity?> currentIdentity() async {
    if (access != null) {
      final capability = await access!.currentNetworkCapability();
      return capability == null
          ? null
          : (capability.ownerId, capability.generation);
    }
    final userId = _prefs.getString(activeSessionUserIdPreferenceKey);
    if (userId == null || userId.isEmpty) return null;
    return (userId, await currentGeneration());
  }

  Future<bool> isCurrent({
    required String userId,
    required int generation,
  }) async => await currentIdentity() == (userId, generation);
}

final sessionGenerationRepositoryProvider =
    Provider<SessionGenerationRepository>(
      (ref) => SessionGenerationRepository(
        ref.watch(sharedPreferencesProvider),
        access: ref.watch(workspaceAccessRepositoryProvider),
      ),
    );
