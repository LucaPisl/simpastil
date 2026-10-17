import 'dart:io';

import 'protected_file_store.dart';

enum StorageCategory {
  care,
  recovery,
  unfinished,
  legacyPlaintext,
  otherPrivate,
}

class StorageInventory {
  const StorageInventory(this.sizes, {this.availableBytes});
  final Map<StorageCategory, int?> sizes;
  final int? availableBytes;
}

/// Unknown sizes remain null; database drafts/queues are included in care.
class StorageInventoryService {
  const StorageInventoryService(
    this.store,
    this.legacy, {
    this.availableBytes,
    this.measure = _fileLength,
  });
  final ProtectedFileStore store;
  final File legacy;
  final Future<int?> Function()? availableBytes;
  final Future<int> Function(File file) measure;
  static Future<int> _fileLength(File file) => file.length();

  Future<StorageInventory> scan() async {
    final sizes = <StorageCategory, int?>{
      for (final category in StorageCategory.values) category: 0,
    };
    ProtectedStoreManifest? manifest;
    try {
      manifest = await store.manifest();
    } catch (_) {
      for (final category in StorageCategory.values) {
        sizes[category] = null;
      }
    }
    Future<void> add(StorageCategory category, File file) async {
      try {
        final length = await measure(file);
        if (length < 0) throw const FileSystemException();
        if (sizes[category] != null) {
          sizes[category] = sizes[category]! + length;
        }
      } catch (_) {
        sizes[category] = null;
      }
    }

    try {
      await for (final entry in store.root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is Link) {
          sizes[StorageCategory.otherPrivate] = null;
          continue;
        }
        if (entry is! File) continue;
        final relative = entry.path
            .substring(store.root.path.length + 1)
            .split('/');
        final generation = relative.first;
        final name = relative.last;
        final category =
            generation == manifest?.active && name.startsWith('care.db')
            ? StorageCategory.care
            : {
                    manifest?.recovery,
                    manifest?.originalRecovery,
                  }.contains(generation) &&
                  name != 'generation.json'
            ? StorageCategory.recovery
            : (generation.startsWith('generation-') &&
                      !{
                        manifest?.active,
                        manifest?.recovery,
                        manifest?.originalRecovery,
                      }.contains(generation)) ||
                  generation.startsWith('discard-generation-')
            ? StorageCategory.unfinished
            : StorageCategory.otherPrivate;
        await add(category, entry);
      }
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final file = File('${legacy.path}$suffix');
        if (await file.exists()) {
          await add(StorageCategory.legacyPlaintext, file);
        }
      }
    } catch (_) {
      for (final category in StorageCategory.values) {
        sizes[category] = null;
      }
    }
    int? free;
    try {
      free = await availableBytes?.call();
      if (free != null && free < 0) free = null;
    } catch (_) {
      free = null;
    }
    return StorageInventory(Map.unmodifiable(sizes), availableBytes: free);
  }
}
