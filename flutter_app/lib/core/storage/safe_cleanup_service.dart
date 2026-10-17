import 'dart:convert';
import 'dart:io';

import 'protected_file_store.dart';
import 'protected_store_gate.dart';
import 'recovery_copy_service.dart';

enum CleanupState { complete, stale, refused, failed }

enum CleanupPoint { quarantined, deleted }

class CleanupPlan {
  CleanupPlan._(this.revision, this.generations);
  final String revision;
  final List<String> generations;
}

class CleanupResult {
  const CleanupResult(this.state, this.removed);
  final CleanupState state;
  final int removed;
}

/// Only proven never-published startup generations can be removed. Published
/// care, drafts, queues, current work and authoritative recoveries are excluded.
class SafeCleanupService {
  const SafeCleanupService(
    this.store, {
    required this.syncDirectory,
    this.deleteDirectory = _delete,
    this.stageIntent = _stageIntent,
    this.onPoint,
  });
  final ProtectedFileStore store;
  final Future<void> Function(String) syncDirectory;
  final Future<void> Function(Directory) deleteDirectory;
  final Future<void> Function(File, String) stageIntent;
  final Future<void> Function(CleanupPoint)? onPoint;
  static Future<void> _delete(Directory directory) async =>
      directory.delete(recursive: true);
  static Future<void> _stageIntent(File file, String value) async =>
      file.writeAsString(value, flush: true);

  Future<CleanupPlan> plan() => withProtectedStoreGate(store.root, () async {
    final manifest = await store.manifest();
    final candidates = <String>[];
    await for (final entry in store.root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final generation = entry.path.split('/').last;
      if (!manifest.retained.contains(generation) &&
          await _eligible(generation)) {
        candidates.add(generation);
      }
    }
    return CleanupPlan._(manifest.revision, List.unmodifiable(candidates));
  });

  Future<CleanupResult> execute(CleanupPlan plan) async {
    var removed = 0;
    try {
      return await withProtectedStoreGate(store.root, () async {
        final manifest = await store.manifest();
        if (manifest.revision != plan.revision) {
          return const CleanupResult(CleanupState.stale, 0);
        }
        await store.verify(manifest.active, 'care.db');
        final copies = RecoveryCopyService(store);
        for (final original in [false, true]) {
          final copy = await copies.check(manifest, original: original);
          if (copy.state == RecoveryCopyState.unavailable) {
            return const CleanupResult(CleanupState.refused, 0);
          }
        }
        final intentFile = File('${store.root.path}/cleanup.json');
        final completed = <String>{};
        if (await intentFile.exists()) {
          if (await intentFile.length() > 2048) {
            return const CleanupResult(CleanupState.refused, 0);
          }
          final intent = jsonDecode(await intentFile.readAsString()) as Map;
          final generation = intent['generation'];
          if (intent['version'] != 1 ||
              intent['purpose'] != 'neverPublishedStartupCleanup' ||
              generation is! String ||
              manifest.retained.contains(generation)) {
            return const CleanupResult(CleanupState.refused, 0);
          }
          final quarantined = Directory(
            '${store.root.path}/discard-$generation',
          );
          if (await quarantined.exists()) {
            if (!await _quarantineSafe(generation)) {
              return const CleanupResult(CleanupState.refused, 0);
            }
            await deleteDirectory(quarantined);
            await syncDirectory(store.root.path);
            removed++;
            completed.add(generation);
          } else if (!await Directory(
            '${store.root.path}/$generation',
          ).exists()) {
            completed.add(generation);
          }
          await intentFile.delete();
          await syncDirectory(store.root.path);
        }
        for (final generation in plan.generations) {
          if (completed.contains(generation)) continue;
          if (manifest.retained.contains(generation) ||
              !await _eligible(generation)) {
            return CleanupResult(CleanupState.refused, removed);
          }
          final staged = File('${store.root.path}/cleanup.next');
          await stageIntent(
            staged,
            jsonEncode({
              'version': 1,
              'purpose': 'neverPublishedStartupCleanup',
              'generation': generation,
            }),
          );
          await staged.rename(intentFile.path);
          await syncDirectory(store.root.path);
          final source = Directory('${store.root.path}/$generation');
          final quarantined = await source.rename(
            '${store.root.path}/discard-$generation',
          );
          await syncDirectory(store.root.path);
          await onPoint?.call(CleanupPoint.quarantined);
          await deleteDirectory(quarantined);
          await syncDirectory(store.root.path);
          removed++;
          await onPoint?.call(CleanupPoint.deleted);
          await intentFile.delete();
          await syncDirectory(store.root.path);
        }
        return CleanupResult(CleanupState.complete, removed);
      });
    } catch (_) {
      return CleanupResult(CleanupState.failed, removed);
    }
  }

  Future<bool> _quarantineSafe(String generation) async {
    if (!RegExp(r'^generation-[A-Za-z0-9_\-=]{22,24}$').hasMatch(generation)) {
      return false;
    }
    final directory = Directory('${store.root.path}/discard-$generation');
    try {
      if (await directory.resolveSymbolicLinks() !=
          '${await store.root.resolveSymbolicLinks()}/discard-$generation') {
        return false;
      }
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File ||
            !const {
              'generation.json',
              'care.db',
              'recovery.db',
            }.contains(entry.path.split('/').last)) {
          return false;
        }
      }
      final metadata = File('${directory.path}/generation.json');
      return !await metadata.exists() ||
          await _eligible(generation, quarantine: true);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _eligible(String generation, {bool quarantine = false}) async {
    if (!RegExp(r'^generation-[A-Za-z0-9_\-=]{22,24}$').hasMatch(generation)) {
      return false;
    }
    final directory = Directory(
      '${store.root.path}/${quarantine ? 'discard-' : ''}$generation',
    );
    try {
      if (await directory.resolveSymbolicLinks() !=
          '${await store.root.resolveSymbolicLinks()}/${quarantine ? 'discard-' : ''}$generation') {
        return false;
      }
      final metadata = File('${directory.path}/generation.json');
      if (await metadata.length() > 2048) return false;
      final value = jsonDecode(await metadata.readAsString()) as Map;
      if (value['version'] != 1 ||
          value['generation'] != generation ||
          value['purpose'] != 'startupPreparation' ||
          value['everPublished'] != false) {
        return false;
      }
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File ||
            !const {
              'generation.json',
              'care.db',
              'recovery.db',
            }.contains(entry.path.split('/').last)) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
