import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'backup_manifest.dart';

/// Version 1 authenticates its exact fixed header and all portable contents.
/// Crypto and JSON parsing run off the UI isolate; no plaintext file is made.
class BackupCodec {
  const BackupCodec();
  static const headerBytes = 64;
  static const memoryBlocks = 19 * 1024;
  static const iterations = 2;

  Future<Uint8List> encode(
    BackupDocument document, {
    String? password,
    bool allowClear = false,
  }) {
    if (password == null || password.isEmpty) {
      if (!allowClear) {
        return Future.error(
          const BackupFailure(BackupFailureCode.passwordRequired),
        );
      }
    } else if (utf8.encode(password).length > 4096) {
      return Future.error(const BackupFailure(BackupFailureCode.tooLarge));
    }
    return Isolate.run(() => _encode(document, password));
  }

  Future<BackupDocument> decode(Uint8List file, {String? password}) {
    try {
      _Header.parse(file);
      if (password != null && utf8.encode(password).length > 4096) {
        throw const BackupFailure(BackupFailureCode.tooLarge);
      }
    } on BackupFailure catch (error) {
      return Future.error(error);
    }
    // Isolate.run transfers a private copy of these caller-owned bytes.
    final frozen = Uint8List.fromList(file);
    return Isolate.run(() => _decode(frozen, password));
  }

  bool isPasswordProtected(Uint8List file) => _Header.parse(file).encrypted;

  static Future<SecretKey> _key(String password, List<int> salt) => Argon2id(
    memory: memoryBlocks,
    iterations: iterations,
    parallelism: 1,
    hashLength: 32,
  ).deriveKeyFromPassword(password: password, nonce: salt);

  static Future<Uint8List> _encode(
    BackupDocument document,
    String? password,
  ) async {
    final payload = utf8.encode(document.toJsonText());
    if (payload.length > maximumBackupBytes) {
      throw const BackupFailure(BackupFailureCode.tooLarge);
    }
    final encrypted = password != null && password.isNotEmpty;
    final header = Uint8List(headerBytes);
    header.setRange(0, 8, ascii.encode('SIMPBAK1'));
    final fields = ByteData.sublistView(header);
    fields.setUint16(8, 1, Endian.big);
    header[10] = encrypted ? 1 : 0;
    header[11] = encrypted ? 1 : 0;
    fields.setUint16(12, headerBytes, Endian.big);
    header[14] = encrypted ? 1 : 0;
    fields.setUint32(28, payload.length, Endian.big);
    if (!encrypted) {
      final file = Uint8List(headerBytes + payload.length + 32);
      file.setRange(0, headerBytes, header);
      file.setRange(headerBytes, headerBytes + payload.length, payload);
      file.setRange(
        headerBytes + payload.length,
        file.length,
        hashes.sha256
            .convert(
              Uint8List.sublistView(file, 0, headerBytes + payload.length),
            )
            .bytes,
      );
      return file;
    }
    fields.setUint32(16, memoryBlocks, Endian.big);
    fields.setUint32(20, iterations, Endian.big);
    fields.setUint16(24, 1, Endian.big);
    fields.setUint16(26, 32, Endian.big);
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final algorithm = AesGcm.with256bits();
    final nonce = algorithm.newNonce();
    header.setRange(32, 48, salt);
    header.setRange(48, 60, nonce);
    final secret = await _key(password, salt);
    try {
      final box = await algorithm.encrypt(
        payload,
        secretKey: secret,
        nonce: nonce,
        aad: header,
      );
      final file = Uint8List(headerBytes + box.cipherText.length + 16);
      file.setRange(0, headerBytes, header);
      file.setRange(
        headerBytes,
        headerBytes + box.cipherText.length,
        box.cipherText,
      );
      file.setRange(
        headerBytes + box.cipherText.length,
        file.length,
        box.mac.bytes,
      );
      return file;
    } finally {
      secret.destroy();
    }
  }

  static Future<BackupDocument> _decode(
    Uint8List file,
    String? password,
  ) async {
    final header = _Header.parse(file);
    final payload = Uint8List.sublistView(
      file,
      headerBytes,
      headerBytes + header.length,
    );
    if (!header.encrypted) {
      final checked = Uint8List.sublistView(
        file,
        0,
        headerBytes + header.length,
      );
      final expected = hashes.sha256.convert(checked).bytes;
      final actual = Uint8List.sublistView(file, checked.length);
      var difference = 0;
      for (var i = 0; i < expected.length; i++) {
        difference |= expected[i] ^ actual[i];
      }
      if (difference != 0) {
        throw const BackupFailure(BackupFailureCode.integrity);
      }
      return BackupDocument.parse(payload);
    }
    if (password == null || password.isEmpty) {
      throw const BackupFailure(BackupFailureCode.passwordRequired);
    }
    final secret = await _key(password, Uint8List.sublistView(file, 32, 48));
    try {
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox(
          payload,
          nonce: Uint8List.sublistView(file, 48, 60),
          mac: Mac(Uint8List.sublistView(file, headerBytes + header.length)),
        ),
        secretKey: secret,
        aad: Uint8List.sublistView(file, 0, headerBytes),
      );
      return BackupDocument.parse(plain);
    } on SecretBoxAuthenticationError {
      throw const BackupFailure(BackupFailureCode.passwordOrIntegrity);
    } finally {
      secret.destroy();
    }
  }
}

class _Header {
  const _Header(this.encrypted, this.length);
  final bool encrypted;
  final int length;

  static _Header parse(Uint8List file) {
    if (file.length > maximumBackupBytes + BackupCodec.headerBytes + 32) {
      throw const BackupFailure(BackupFailureCode.tooLarge);
    }
    if (file.length < BackupCodec.headerBytes + 16 ||
        !const ListEquality<int>().equals(
          file.sublist(0, 8),
          ascii.encode('SIMPBAK1'),
        )) {
      throw const BackupFailure(BackupFailureCode.invalidContainer);
    }
    final fields = ByteData.sublistView(file, 0, BackupCodec.headerBytes);
    if (fields.getUint16(8, Endian.big) != 1) {
      throw const BackupFailure(BackupFailureCode.unsupportedVersion);
    }
    if (fields.getUint16(12, Endian.big) != BackupCodec.headerBytes ||
        file[15] != 0 ||
        file.sublist(60, 64).any((v) => v != 0) ||
        !const {0, 1}.contains(file[10])) {
      throw const BackupFailure(BackupFailureCode.invalidContainer);
    }
    final encrypted = file[10] == 1;
    final length = fields.getUint32(28, Endian.big);
    if (length == 0 ||
        length > maximumBackupBytes ||
        file.length !=
            BackupCodec.headerBytes + length + (encrypted ? 16 : 32)) {
      throw const BackupFailure(BackupFailureCode.invalidContainer);
    }
    if (encrypted) {
      if (file[11] != 1 ||
          file[14] != 1 ||
          fields.getUint32(16, Endian.big) != BackupCodec.memoryBlocks ||
          fields.getUint32(20, Endian.big) != BackupCodec.iterations ||
          fields.getUint16(24, Endian.big) != 1 ||
          fields.getUint16(26, Endian.big) != 32) {
        throw const BackupFailure(BackupFailureCode.invalidContainer);
      }
    } else if (file[11] != 0 ||
        file[14] != 0 ||
        file.sublist(16, 28).any((v) => v != 0) ||
        file.sublist(32, 60).any((v) => v != 0)) {
      throw const BackupFailure(BackupFailureCode.invalidContainer);
    }
    return _Header(encrypted, length);
  }
}
