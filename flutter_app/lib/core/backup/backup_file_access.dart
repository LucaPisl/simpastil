import 'package:flutter/services.dart';
import 'package:simpastil_storage/simpastil_storage.dart';

import 'backup_manifest.dart';

/// A provider-chosen document. The token is opaque, never a filesystem path.
class BackupFileLocation {
  const BackupFileLocation(this.token, this.displayName);
  final String token;
  final String displayName;
}

abstract interface class BackupFileAccess {
  Future<BackupFileLocation?> chooseSave(String suggestedName);
  Future<BackupFileLocation?> chooseOpen();
  Future<void> write(BackupFileLocation location, Uint8List bytes);
  Future<Uint8List> read(BackupFileLocation location);
}

class AndroidBackupFileAccess implements BackupFileAccess {
  const AndroidBackupFileAccess();

  Future<BackupFileLocation?> _choose(String method, [String? name]) async {
    final value = await SimpastilStorage.channel
        .invokeMapMethod<String, String>(method, {'name': name});
    if (value == null) return null;
    final token = value['token'], displayName = value['displayName'];
    if (token == null || token.isEmpty || displayName == null) {
      throw const BackupFailure(BackupFailureCode.saveFailed);
    }
    return BackupFileLocation(token, displayName);
  }

  @override
  Future<BackupFileLocation?> chooseSave(String suggestedName) =>
      _choose('chooseBackupDestination', suggestedName);
  @override
  Future<BackupFileLocation?> chooseOpen() => _choose('chooseBackupSource');
  @override
  Future<void> write(BackupFileLocation location, Uint8List bytes) {
    if (bytes.length > maximumBackupBytes + 96) {
      throw const BackupFailure(BackupFailureCode.tooLarge);
    }
    return SimpastilStorage.channel.invokeMethod<void>('writeBackupDocument', {
      'token': location.token,
      'bytes': bytes,
    });
  }

  @override
  Future<Uint8List> read(BackupFileLocation location) async {
    Uint8List? bytes;
    try {
      bytes = await SimpastilStorage.channel.invokeMethod<Uint8List>(
        'readBackupDocument',
        {'token': location.token, 'maximumBytes': maximumBackupBytes + 96},
      );
    } on PlatformException catch (error) {
      if (error.code == 'backup_document_too_large') {
        throw const BackupFailure(BackupFailureCode.tooLarge);
      }
      rethrow;
    }
    if (bytes == null || bytes.length > maximumBackupBytes + 96) {
      throw const BackupFailure(BackupFailureCode.tooLarge);
    }
    return bytes;
  }
}
