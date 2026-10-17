import 'package:flutter/services.dart';

class SimpastilStorage {
  const SimpastilStorage();
  static const channel = MethodChannel('simpastil_storage');

  Future<String> noBackupPath() async {
    final path = await channel.invokeMethod<String>('noBackupPath');
    if (path == null || path.isEmpty) {
      throw StateError('Private storage unavailable');
    }
    return path;
  }

  Future<void> syncDirectory(String path) =>
      channel.invokeMethod<void>('syncDirectory', {'path': path});

  /// Wait for the pinned secure-storage plugin's pending Android writes.
  Future<void> flushCredentialStorage() =>
      channel.invokeMethod<void>('flushCredentialStorage');

  Future<int?> availableBytes() => channel.invokeMethod<int>('availableBytes');
}
