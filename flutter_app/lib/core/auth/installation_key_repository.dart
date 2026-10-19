import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../workspace/workspace_provider.dart';
import '../utils/app_logger.dart';
import 'protected_credentials_repository.dart';

/// Installation keys are separate from account tokens. The protected pointer
/// binds each immutable secure slot to the reviewed endpoint and its epoch.
class InstallationKeyRepository {
  InstallationKeyRepository({required this.access, required this.store});
  final WorkspaceAccessRepository access;
  final CredentialSlotStore store;
  static const _ids = Uuid();
  static String _key(String id) => 'simpastil_installation_v2.$id';

  Future<Map<String, dynamic>?> _readFor(InstallationCapability scope) async {
    if (!await access.installationIsCurrent(scope)) return null;
    final id = (await access.workspaces.deviceState()).installationKeyId;
    if (id == null) return null;
    final slot = await (access.database.select(
      access.database.installationKeySlots,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    if (slot?.state != 'published' || slot?.endpoint != scope.endpoint) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    final encoded = await store.read(_key(id));
    if (encoded == null) return null;
    final value = _decodePayload(encoded, scope.endpoint);
    if (!await access.installationIsCurrent(scope) ||
        (await access.workspaces.deviceState()).installationKeyId != id) {
      return null;
    }
    return value;
  }

  Future<String?> readFor(InstallationCapability scope) async =>
      (await _readFor(scope))?['key'] as String?;
  Future<String?> readVerifiedStatusFor(InstallationCapability scope) async =>
      (await _readFor(scope))?['verifiedStatus'] as String?;

  Future<String?> readRevoked(
    NetworkCapability capability,
    RevokedNetworkState revoked,
  ) async {
    final id = revoked.installationKeyId;
    if (id == null ||
        revoked.epoch != capability.epoch + 1 ||
        (await access.workspaces.deviceState()).installationKeyId == id) {
      return null;
    }
    final slot = await (access.database.select(
      access.database.installationKeySlots,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    if (slot?.endpoint != capability.endpoint) return null;
    final encoded = await store.read(_key(id));
    return encoded == null ? null : _decode(encoded, capability.endpoint);
  }

  String _decode(String text, String endpoint) =>
      _decodePayload(text, endpoint)['key'] as String;

  Map<String, dynamic> _decodePayload(String text, String endpoint) {
    if (utf8.encode(text).length > 16384) {
      throw const FormatException('Invalid installation credential');
    }
    Object? value;
    try {
      value = jsonDecode(text);
    } on FormatException {
      throw const FormatException('Invalid installation credential');
    }
    if (value is! Map<String, dynamic> ||
        !((value['version'] == 1 && value.length == 3) ||
            (value['version'] == 2 &&
                value.length == 4 &&
                const {
                  'owned',
                  'unclaimed',
                }.contains(value['verifiedStatus']))) ||
        value['endpoint'] != endpoint ||
        value['key'] is! String ||
        (value['key'] as String).isEmpty ||
        (value['key'] as String).length > 8192) {
      throw const FormatException('Invalid installation credential');
    }
    return value;
  }

  Future<InstallationCapability> saveFor(
    InstallationCapability scope,
    String key, {
    String? verifiedStatus,
  }) async {
    final encoded = jsonEncode({
      'version': verifiedStatus == null ? 1 : 2,
      'verifiedStatus': ?verifiedStatus,
      'endpoint': scope.endpoint,
      'key': key,
    });
    _decode(encoded, scope.endpoint);
    final id = _ids.v4();
    await store.write(_key(id), encoded);
    if (await store.read(_key(id)) != encoded) {
      await store.delete(_key(id));
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    String? prior;
    var published = false;
    try {
      await access.database.transaction(() async {
        if (!await access.installationIsCurrent(scope)) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.staleNetworkTransition,
          );
        }
        prior = (await access.workspaces.deviceState()).installationKeyId;
        await access.database
            .into(access.database.installationKeySlots)
            .insert(
              InstallationKeySlotsCompanion.insert(
                id: id,
                endpoint: scope.endpoint,
                state: 'published',
                createdAt: DateTime.now().toUtc(),
              ),
            );
        await (access.database.update(
          access.database.workspaceDeviceStates,
        )..where((row) => row.id.equals('device'))).write(
          WorkspaceDeviceStatesCompanion(
            installationKeyId: Value(id),
            installationEpoch: Value(scope.epoch + 1),
          ),
        );
      });
      published = true;
    } finally {
      // Ambiguous post-commit outcomes must never delete the selected winner.
      if (!published &&
          (await access.workspaces.deviceState()).installationKeyId != id) {
        await store.delete(_key(id));
      }
    }
    if (prior != null) {
      try {
        await discardUnreferenced(prior!);
      } on Object catch (error) {
        AppLogger.warning(
          'InstallationKey',
          'Prior cleanup deferred: ${error.runtimeType}',
        );
      }
    }
    return InstallationCapability(
      endpoint: scope.endpoint,
      epoch: scope.epoch + 1,
      networkEpoch: scope.networkEpoch,
    );
  }

  Future<void> clearFor(InstallationCapability scope) async {
    final prior = await access.database.transaction(() async {
      if (!await access.installationIsCurrent(scope)) return null;
      final id = (await access.workspaces.deviceState()).installationKeyId;
      await (access.database.update(
        access.database.workspaceDeviceStates,
      )..where((row) => row.id.equals('device'))).write(
        WorkspaceDeviceStatesCompanion(
          installationKeyId: const Value(null),
          installationEpoch: Value(scope.epoch + 1),
        ),
      );
      return id;
    });
    if (prior != null) await discardUnreferenced(prior);
  }

  Future<void> discardUnreferenced(String id) async {
    final claimed = await access.database.transaction(() async {
      if ((await access.workspaces.deviceState()).installationKeyId == id) {
        return false;
      }
      final updated =
          await (access.database.update(
            access.database.installationKeySlots,
          )..where((row) => row.id.equals(id))).write(
            const InstallationKeySlotsCompanion(state: Value('discarded')),
          );
      return updated == 1;
    });
    if (claimed) await store.delete(_key(id));
  }
}

final installationKeyRepositoryProvider = Provider<InstallationKeyRepository>(
  (ref) => InstallationKeyRepository(
    access: ref.watch(workspaceAccessRepositoryProvider),
    store: const SecureCredentialSlotStore(),
  ),
);
