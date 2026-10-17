import 'dart:convert';
import 'dart:io';
import 'package:simpastil_storage/simpastil_storage.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../workspace/workspace_provider.dart';
import '../db/database.dart';

abstract interface class CredentialSlotStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureCredentialSlotStore implements CredentialSlotStore {
  const SecureCredentialSlotStore();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      keyCipherAlgorithm:
          KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
    if (Platform.isAndroid) {
      await const SimpastilStorage().flushCredentialStorage();
    }
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class CredentialBundle {
  const CredentialBundle({
    required this.ownerId,
    required this.endpoint,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAtMillis,
  });
  final String ownerId;
  final String endpoint;
  final String accessToken;
  final String refreshToken;
  final int expiresAtMillis;

  static CredentialBundle fromResponse(
    Map<String, dynamic> data,
    String endpoint,
  ) {
    try {
      final access = data['accessToken'];
      final refresh = data['refreshToken'];
      if (access is! String || refresh is! String) {
        throw const FormatException();
      }
      final parts = access.split('.');
      if (parts.length != 3) throw const FormatException();
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (claims is! Map<String, dynamic> ||
          claims['sub'] is! String ||
          claims['exp'] is! int) {
        throw const FormatException();
      }
      final bundle = CredentialBundle(
        ownerId: claims['sub'] as String,
        endpoint: canonicalServerEndpoint(endpoint),
        accessToken: access,
        refreshToken: refresh,
        expiresAtMillis: (claims['exp'] as int) * 1000,
      );
      return decode(bundle.encode());
    } catch (_) {
      throw const FormatException('Invalid credential response');
    }
  }

  String encode() => jsonEncode({
    'version': 1,
    'ownerId': ownerId,
    'endpoint': endpoint,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAtMillis': expiresAtMillis,
  });

  static CredentialBundle decode(String text) {
    if (utf8.encode(text).length > 32768) {
      throw const FormatException('Invalid credential bundle');
    }
    Object? value;
    try {
      value = jsonDecode(text);
    } on FormatException {
      throw const FormatException('Invalid credential bundle');
    }
    if (value is! Map<String, dynamic> ||
        value.length != 6 ||
        value['version'] != 1 ||
        value['ownerId'] is! String ||
        value['endpoint'] is! String ||
        value['accessToken'] is! String ||
        value['refreshToken'] is! String ||
        value['expiresAtMillis'] is! int) {
      throw const FormatException('Invalid credential bundle');
    }
    final bundle = CredentialBundle(
      ownerId: value['ownerId'] as String,
      endpoint: value['endpoint'] as String,
      accessToken: value['accessToken'] as String,
      refreshToken: value['refreshToken'] as String,
      expiresAtMillis: value['expiresAtMillis'] as int,
    );
    if (bundle.ownerId.isEmpty ||
        bundle.ownerId.length > 128 ||
        bundle.endpoint.length > 2048 ||
        canonicalServerEndpoint(bundle.endpoint) != bundle.endpoint ||
        bundle.accessToken.isEmpty ||
        bundle.accessToken.length > 8192 ||
        bundle.refreshToken.isEmpty ||
        bundle.refreshToken.length > 8192 ||
        bundle.expiresAtMillis < 0 ||
        bundle.expiresAtMillis > 8640000000000000) {
      throw const FormatException('Invalid credential bundle');
    }
    return bundle;
  }

  @override
  String toString() => 'CredentialBundle(protected)';
}

class ReadCredentialBundle {
  const ReadCredentialBundle(this.credentialId, this.bundle);
  final String credentialId;
  final CredentialBundle bundle;
  @override
  String toString() => 'ReadCredentialBundle(protected)';
}

/// Secure bundles are immutable. Only the protected DB publishes their random
/// identity, so a losing/late reply cannot overwrite the winner's credentials.
class ProtectedCredentialsRepository {
  ProtectedCredentialsRepository({required this.access, required this.store});
  final WorkspaceAccessRepository access;
  final CredentialSlotStore store;
  static const _ids = Uuid();
  static String _key(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id)) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    return 'simpastil_credentials_v2.$id';
  }

  Future<String> stage(CredentialBundle bundle) async {
    final serialized = bundle.encode();
    CredentialBundle.decode(serialized);
    final id = _ids.v4();
    final key = _key(id);
    await store.write(key, serialized);
    final reopened = await store.read(key);
    if (reopened != serialized) {
      await store.delete(key);
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    CredentialBundle.decode(reopened!);
    try {
      await access.database
          .into(access.database.credentialSlots)
          .insert(
            CredentialSlotsCompanion.insert(
              id: id,
              ownerId: bundle.ownerId,
              endpoint: bundle.endpoint,
              state: 'staged',
              createdAt: DateTime.now().toUtc(),
            ),
          );
    } catch (_) {
      // This ID has not been returned or registered; no activation can own it.
      await store.delete(key);
      rethrow;
    }
    return id;
  }

  Future<CredentialBundle> stagedBundle(String credentialId) async {
    final stored = await store.read(_key(credentialId));
    if (stored == null) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    return CredentialBundle.decode(stored);
  }

  Future<AuthenticatedWorkspace> activate({
    required String credentialId,
    required int expectedTransition,
    required int sessionGeneration,
    InstallationCapability? installation,
  }) async {
    final stored = await store.read(_key(credentialId));
    if (stored == null) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    final bundle = CredentialBundle.decode(stored);
    try {
      return await access.authenticate(
        ownerId: bundle.ownerId,
        endpoint: bundle.endpoint,
        expectedNetworkEpoch: expectedTransition,
        sessionGeneration: sessionGeneration,
        credentialId: credentialId,
        installation: installation,
      );
    } catch (_) {
      // This check also covers ambiguous post-commit errors. Never remove the
      // winning pointer's slot merely because its caller did not get a result.
      await discardUnreferenced(credentialId);
      rethrow;
    }
  }

  Future<ReadCredentialBundle?> readFor(NetworkCapability capability) async {
    if (!await access.networkIsCurrent(capability)) return null;
    final state = await access.workspaces.deviceState();
    final id = state.networkCredentialId;
    if (id == null) return null;
    final serialized = await store.read(_key(id));
    if (serialized == null) return null;
    final bundle = CredentialBundle.decode(serialized);
    if (bundle.ownerId != capability.ownerId ||
        bundle.endpoint != capability.endpoint ||
        !await access.networkIsCurrent(capability)) {
      return null;
    }
    final after = await access.workspaces.deviceState();
    if (after.networkCredentialId != id) return null;
    return ReadCredentialBundle(id, bundle);
  }

  /// Optional remote logout reads the exact retired slot returned by durable
  /// revocation. It never reads through the current/new account pointer.
  Future<ReadCredentialBundle?> readRevoked(
    NetworkCapability capability,
    RevokedNetworkState revoked,
  ) async {
    final id = revoked.credentialId;
    if (id == null ||
        revoked.epoch != capability.epoch + 1 ||
        (await access.workspaces.deviceState()).networkCredentialId == id) {
      return null;
    }
    final slot = await (access.database.select(
      access.database.credentialSlots,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    if (slot == null ||
        slot.ownerId != capability.ownerId ||
        slot.endpoint != capability.endpoint) {
      return null;
    }
    final encoded = await store.read(_key(id));
    if (encoded == null) return null;
    final bundle = CredentialBundle.decode(encoded);
    if (bundle.ownerId != capability.ownerId ||
        bundle.endpoint != capability.endpoint) {
      return null;
    }
    return ReadCredentialBundle(id, bundle);
  }

  Future<bool> replace(
    NetworkCapability capability, {
    required String expectedCredentialId,
    required String stagedCredentialId,
  }) async {
    final stored = await store.read(_key(stagedCredentialId));
    if (stored == null) return false;
    final bundle = CredentialBundle.decode(stored);
    if (bundle.ownerId != capability.ownerId ||
        bundle.endpoint != capability.endpoint) {
      return false;
    }
    final replaced = await access.replaceCredentials(
      capability,
      expectedCredentialId: expectedCredentialId,
      stagedCredentialId: stagedCredentialId,
    );
    if (!replaced) {
      await discardUnreferenced(stagedCredentialId);
    }
    return replaced;
  }

  Future<void> discardUnreferenced(String id) async {
    if (await access.claimCredentialDiscard(id)) await store.delete(_key(id));
  }
}

final protectedCredentialsRepositoryProvider =
    Provider<ProtectedCredentialsRepository>(
      (ref) => ProtectedCredentialsRepository(
        access: ref.watch(workspaceAccessRepositoryProvider),
        store: const SecureCredentialSlotStore(),
      ),
    );
