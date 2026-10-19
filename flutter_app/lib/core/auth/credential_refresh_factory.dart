import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simpastil_storage/simpastil_storage.dart';

import '../workspace/workspace_context.dart';
import 'credential_refresh_coordinator.dart';
import 'installation_key_repository.dart';
import 'protected_credentials_repository.dart';

Future<CredentialRefreshGate> createNativeCredentialRefreshGate() async {
  const storage = SimpastilStorage();
  return NativeCredentialRefreshGate(
    directory: Directory('${await storage.noBackupPath()}/auth'),
    syncDirectory: (directory) => storage.syncDirectory(directory.path),
  );
}

final credentialRefreshGateProvider =
    Provider<Future<CredentialRefreshGate> Function()>(
      (ref) => createNativeCredentialRefreshGate,
    );

CredentialRefreshCoordinator createCredentialRefreshCoordinator({
  required ProtectedCredentialsRepository credentials,
  required InstallationKeyRepository keys,
  required CredentialRefreshGate gate,
  required String endpoint,
  NetworkCapability? capability,
  Dio? refreshDio,
}) {
  final dio =
      refreshDio ??
      Dio(
        BaseOptions(
          baseUrl: '$endpoint/api/v1',
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: false,
        ),
      );
  Future<Map<String, String>> authorizedHeaders() async {
    final captured = capability;
    if (captured == null ||
        !await credentials.access.networkIsCurrent(captured)) {
      throw const CredentialRefreshNotConsumed(CredentialRefreshOutcome.stale);
    }
    final scope = await credentials.access.captureInstallation(endpoint);
    if (scope == null || scope.networkEpoch != captured.epoch) {
      throw const CredentialRefreshNotConsumed(CredentialRefreshOutcome.stale);
    }
    final apiKey = await keys.readFor(scope);
    if (!await credentials.access.networkIsCurrent(captured) ||
        !await credentials.access.installationIsCurrent(scope)) {
      throw const CredentialRefreshNotConsumed(CredentialRefreshOutcome.stale);
    }
    return {'X-Api-Key': ?apiKey};
  }

  Never classify(DioException error) {
    final data = error.response?.data;
    final code = data is Map<String, dynamic> ? data['code'] : null;
    if (const {401, 403}.contains(error.response?.statusCode)) {
      if (const {'AUTH_KEY_INVALID', 'AUTH_KEY_REVOKED'}.contains(code)) {
        throw const CredentialRefreshNotConsumed(
          CredentialRefreshOutcome.installationRequired,
        );
      }
      if (const {
        'AUTH_UNAUTHORIZED',
        'AUTH_TOKEN_EXPIRED',
        'AUTH_SESSION_REVOKED',
        'AUTH_TOKEN_REUSE',
      }.contains(code)) {
        throw const CredentialRefreshRejected();
      }
    }
    if (error.response?.statusCode == 429 && code == 'RATE_LIMIT_EXCEEDED') {
      throw const CredentialRefreshNotConsumed(CredentialRefreshOutcome.busy);
    }
    throw error;
  }

  Future<CredentialBundle> request(
    CredentialBundle current, [
    String? successor,
  ]) async {
    if (current.ownerId != capability?.ownerId ||
        current.endpoint != endpoint) {
      throw const CredentialRefreshNotConsumed(CredentialRefreshOutcome.stale);
    }
    final headers = await authorizedHeaders();
    try {
      final response = await dio.post<Map<String, dynamic>>(
        successor == null ? '/auth/refresh' : '/auth/refresh/recoverable',
        data: {
          'refreshToken': current.refreshToken,
          'nextRefreshToken': ?successor,
        },
        options: Options(followRedirects: false, headers: headers),
      );
      if (response.data == null) {
        throw const FormatException('Invalid credential response');
      }
      return CredentialBundle.fromResponse(response.data!, endpoint);
    } on DioException catch (error) {
      classify(error);
    }
  }

  return CredentialRefreshCoordinator(
    credentials: credentials,
    gate: gate,
    request: request,
    requestRecoverable: request,
    supportsRecovery: () async {
      final headers = await authorizedHeaders();
      try {
        final response = await dio.get<Map<String, dynamic>>(
          '/capabilities',
          options: Options(followRedirects: false, headers: headers),
        );
        final contracts = response.data?['contracts'];
        if (response.data?['apiNamespace'] != 'v1' || contracts is! Map) {
          throw const FormatException('Invalid capabilities');
        }
        return contracts['refreshRecovery'] == 1;
      } on DioException catch (error) {
        // Discovery cannot consume a refresh token. Unsupported installations
        // use the existing one-shot protocol; transport failures remain retryable.
        if (error.response?.statusCode == 404) return false;
        classify(error);
      }
    },
  );
}
