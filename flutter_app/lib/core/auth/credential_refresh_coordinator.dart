import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import '../workspace/workspace_context.dart';
import '../workspace/workspace_access_repository.dart';
import 'protected_credentials_repository.dart';

enum CredentialRefreshOutcome {
  ready,
  stale,
  busy,
  uncertain,
  rejected,
  installationRequired,
}

class CredentialRefreshRejected implements Exception {
  const CredentialRefreshRejected();
}

/// Use only when a known server guard or a pre-send check proves that the
/// refresh handler did not consume this token. An ambiguous response differs.
class CredentialRefreshNotConsumed implements Exception {
  const CredentialRefreshNotConsumed(this.outcome);
  final CredentialRefreshOutcome outcome;
}

enum CredentialRefreshAttemptState { sending, rejected, notConsumed }

class CredentialRefreshAttempt {
  const CredentialRefreshAttempt(
    this.credentialId,
    this.state, {
    this.proposalId,
    this.responseId,
  });
  final String credentialId;
  final CredentialRefreshAttemptState state;
  final String? proposalId;
  final String? responseId;
}

abstract interface class CredentialRefreshJournal {
  Future<CredentialRefreshAttempt?> currentAttempt();
  Future<void> markSending(String credentialId, {String? proposalId});
  Future<void> markResponse(
    String credentialId,
    String responseId, {
    String? proposalId,
  });
  Future<void> markRejected(String credentialId);
  Future<void> markNotConsumed(String credentialId);
  Future<void> clear();
}

abstract interface class CredentialRefreshGate {
  Future<T> run<T>(Future<T> Function(CredentialRefreshJournal journal) action);
}

class CredentialRefreshBusy implements Exception {
  const CredentialRefreshBusy();
}

/// No care transaction is held across a network request. This independent
/// private gate serializes token use across engines before reading/sending it.
class NativeCredentialRefreshGate implements CredentialRefreshGate {
  NativeCredentialRefreshGate({
    required this.directory,
    required this.syncDirectory,
  });
  final Directory directory;
  final Future<void> Function(Directory) syncDirectory;

  @override
  Future<T> run<T>(
    Future<T> Function(CredentialRefreshJournal journal) action,
  ) async {
    final existed = await directory.exists();
    await directory.create(recursive: true);
    if (!existed) await syncDirectory(directory.parent);
    final gate = sqlite3.open('${directory.path}/refresh-gate.sqlite');
    var held = false;
    try {
      gate.execute('PRAGMA busy_timeout=0');
      final elapsed = Stopwatch()..start();
      while (!held) {
        try {
          gate.execute('BEGIN EXCLUSIVE');
          held = true;
        } on SqliteException catch (error) {
          if (!const {5, 6}.contains(error.resultCode)) rethrow;
          if (elapsed.elapsed >= const Duration(seconds: 3)) {
            throw const CredentialRefreshBusy();
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      return await action(_FileRefreshJournal(directory, syncDirectory));
    } finally {
      try {
        if (held) gate.execute('ROLLBACK');
      } finally {
        gate.close();
      }
    }
  }
}

class _FileRefreshJournal implements CredentialRefreshJournal {
  _FileRefreshJournal(this.directory, this.syncDirectory);
  final Directory directory;
  final Future<void> Function(Directory) syncDirectory;
  File get _intent => File('${directory.path}/refresh.json');
  File get _next => File('${directory.path}/refresh.next');

  Future<CredentialRefreshAttempt?> _read(File file) async {
    if (!await file.exists()) return null;
    if (await file.length() > 2048) {
      throw const FormatException('Invalid refresh state');
    }
    Object? value;
    try {
      value = jsonDecode(await file.readAsString());
    } on FormatException {
      throw const FormatException('Invalid refresh state');
    }
    bool slot(Object? id) =>
        id is String && RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id);
    if (value is! Map<String, dynamic> ||
        !((value['version'] == 1 && value.length == 3) ||
            (value['version'] == 2 && value.length == 5)) ||
        !const {
          'sending',
          'rejected',
          'notConsumed',
        }.contains(value['state']) ||
        !slot(value['credentialId']) ||
        (value['proposalId'] != null && !slot(value['proposalId'])) ||
        (value['responseId'] != null && !slot(value['responseId']))) {
      throw const FormatException('Invalid refresh state');
    }
    return CredentialRefreshAttempt(
      value['credentialId'] as String,
      CredentialRefreshAttemptState.values.byName(value['state'] as String),
      proposalId: value['proposalId'] as String?,
      responseId: value['responseId'] as String?,
    );
  }

  @override
  Future<CredentialRefreshAttempt?> currentAttempt() async {
    final intent = await _read(_intent);
    CredentialRefreshAttempt? next;
    try {
      next = await _read(_next);
    } on FormatException {
      // A crash may interrupt the next write. The atomically published receipt
      // still owns the attempt; an exact recoverable retry can finish it.
      if (intent == null) rethrow;
      return intent;
    }
    if (intent != null && next != null) {
      if (intent.credentialId != next.credentialId ||
          (next.state == CredentialRefreshAttemptState.sending &&
              intent.proposalId != next.proposalId)) {
        throw const FormatException('Ambiguous refresh state');
      }
      if (next.state == CredentialRefreshAttemptState.rejected ||
          next.state == CredentialRefreshAttemptState.notConsumed ||
          (next.responseId != null && intent.responseId == null)) {
        return next;
      }
      if (intent.state != next.state || intent.responseId != next.responseId) {
        throw const FormatException('Ambiguous refresh state');
      }
    }
    return intent ?? next;
  }

  @override
  Future<void> markSending(String credentialId, {String? proposalId}) => _write(
    CredentialRefreshAttempt(
      credentialId,
      CredentialRefreshAttemptState.sending,
      proposalId: proposalId,
    ),
  );

  @override
  Future<void> markResponse(
    String credentialId,
    String responseId, {
    String? proposalId,
  }) => _write(
    CredentialRefreshAttempt(
      credentialId,
      CredentialRefreshAttemptState.sending,
      proposalId: proposalId,
      responseId: responseId,
    ),
  );

  @override
  Future<void> markRejected(String credentialId) => _write(
    CredentialRefreshAttempt(
      credentialId,
      CredentialRefreshAttemptState.rejected,
    ),
  );

  @override
  Future<void> markNotConsumed(String credentialId) => _write(
    CredentialRefreshAttempt(
      credentialId,
      CredentialRefreshAttemptState.notConsumed,
    ),
  );

  Future<void> _write(CredentialRefreshAttempt attempt) async {
    await _next.writeAsString(
      jsonEncode({
        'version': 2,
        'state': attempt.state.name,
        'credentialId': attempt.credentialId,
        'proposalId': attempt.proposalId,
        'responseId': attempt.responseId,
      }),
      flush: true,
    );
    await _next.rename(_intent.path);
    await syncDirectory(directory);
  }

  @override
  Future<void> clear() async {
    if (await _intent.exists()) await _intent.delete();
    if (await _next.exists()) await _next.delete();
    await syncDirectory(directory);
  }
}

class CredentialRefreshCoordinator {
  CredentialRefreshCoordinator({
    required this.credentials,
    required this.gate,
    required this.request,
    this.supportsRecovery,
    this.requestRecoverable,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final ProtectedCredentialsRepository credentials;
  final CredentialRefreshGate gate;
  final Future<CredentialBundle> Function(CredentialBundle current) request;
  final DateTime Function() clock;
  final Future<bool> Function()? supportsRecovery;
  final Future<CredentialBundle> Function(
    CredentialBundle current,
    String successor,
  )?
  requestRecoverable;

  /// Retire old evidence before publishing a staged fresh login, under the
  /// same gate. The old account must already be revoked; an already published
  /// slot cannot clear evidence of its own consumed refresh token.
  Future<AuthenticatedWorkspace> activateFreshAuthentication({
    required String credentialId,
    required int expectedTransition,
    required int sessionGeneration,
    InstallationCapability? installation,
  }) => gate.run((journal) async {
    final candidate = await credentials.stagedBundle(credentialId);
    await credentials.access.requireFreshCredentialTransition(
      credentialId: credentialId,
      ownerId: candidate.ownerId,
      endpoint: candidate.endpoint,
      expectedTransition: expectedTransition,
      installation: installation,
    );
    await journal.clear();
    final activated = await credentials.activate(
      credentialId: credentialId,
      expectedTransition: expectedTransition,
      sessionGeneration: sessionGeneration,
      installation: installation,
    );
    return activated;
  });

  Future<CredentialRefreshOutcome> _finishRejection(
    CredentialRefreshJournal journal,
    NetworkCapability capability,
    String credentialId,
  ) async {
    // On failure the terminal receipt remains. A later process resumes durable
    // revocation rather than downgrading a known rejection to uncertainty.
    final revoked = await credentials.access.revokeIfCurrent(capability);
    if (revoked) await credentials.discardUnreferenced(credentialId);
    await journal.clear();
    return revoked
        ? CredentialRefreshOutcome.rejected
        : CredentialRefreshOutcome.stale;
  }

  /// failedCredentialId names the bundle used by a rejected HTTP request. If
  /// another engine has already replaced it, use that winner without resending.
  Future<CredentialRefreshOutcome> refresh(
    NetworkCapability capability, {
    String? failedCredentialId,
  }) async {
    try {
      return await gate.run((journal) async {
        final current = await credentials.readFor(capability);
        if (current == null) return CredentialRefreshOutcome.stale;
        var pending = await journal.currentAttempt();
        if (pending?.credentialId == current.credentialId) {
          if (pending!.state == CredentialRefreshAttemptState.rejected) {
            return _finishRejection(journal, capability, current.credentialId);
          }
          if (pending.responseId != null) {
            if (!await credentials.replace(
              capability,
              expectedCredentialId: current.credentialId,
              stagedCredentialId: pending.responseId!,
            )) {
              return CredentialRefreshOutcome.stale;
            }
            await journal.clear();
            await credentials.discardUnreferenced(current.credentialId);
            if (pending.proposalId != null) {
              await credentials.discardUnreferenced(pending.proposalId!);
            }
            return CredentialRefreshOutcome.ready;
          }
          if (pending.state == CredentialRefreshAttemptState.sending &&
              (pending.proposalId == null || requestRecoverable == null)) {
            return CredentialRefreshOutcome.uncertain;
          }
        } else if (pending != null) {
          await journal.clear();
          pending = null;
        }
        if (pending?.state == CredentialRefreshAttemptState.notConsumed) {
          await journal.clear();
          pending = null;
        }

        if (pending == null &&
            failedCredentialId != null &&
            failedCredentialId != current.credentialId) {
          return CredentialRefreshOutcome.ready;
        }
        if (pending == null &&
            failedCredentialId == null &&
            current.bundle.expiresAtMillis >
                clock()
                    .add(const Duration(seconds: 30))
                    .millisecondsSinceEpoch) {
          return CredentialRefreshOutcome.ready;
        }
        var proposalId = pending?.proposalId;
        if (pending == null) {
          bool recovery;
          try {
            recovery =
                requestRecoverable != null &&
                await (supportsRecovery?.call() ?? Future.value(false));
          } on CredentialRefreshNotConsumed catch (error) {
            return error.outcome;
          } catch (_) {
            // Capability discovery has not submitted a refresh credential.
            return CredentialRefreshOutcome.busy;
          }
          if (recovery) {
            final random = Random.secure();
            final successor = List.generate(
              32,
              (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
            ).join();
            proposalId = await credentials.stage(
              CredentialBundle(
                ownerId: current.bundle.ownerId,
                endpoint: current.bundle.endpoint,
                accessToken: current.bundle.accessToken,
                refreshToken: successor,
                expiresAtMillis: current.bundle.expiresAtMillis,
              ),
            );
          }
          await journal.markSending(
            current.credentialId,
            proposalId: proposalId,
          );
        }
        if (!await credentials.access.networkIsCurrent(capability)) {
          return CredentialRefreshOutcome.stale;
        }
        CredentialBundle response;
        try {
          if (proposalId == null) {
            response = await request(current.bundle);
          } else {
            final proposal = await credentials.stagedBundle(proposalId);
            if (proposal.ownerId != capability.ownerId ||
                proposal.endpoint != capability.endpoint) {
              return CredentialRefreshOutcome.uncertain;
            }
            response = await requestRecoverable!(
              current.bundle,
              proposal.refreshToken,
            );
            if (response.refreshToken != proposal.refreshToken) {
              return CredentialRefreshOutcome.uncertain;
            }
          }
        } on CredentialRefreshNotConsumed catch (notConsumed) {
          // A refusal of a retry cannot disprove an earlier committed rotation.
          if (proposalId == null) {
            await journal.markNotConsumed(current.credentialId);
            await journal.clear();
          }
          return notConsumed.outcome;
        } on CredentialRefreshRejected {
          await journal.markRejected(current.credentialId);
          return _finishRejection(journal, capability, current.credentialId);
        } catch (_) {
          // Transport failure can occur after consumption. Keep its durable
          // receipt and authorized offline care; do not replay this token.
          return proposalId == null
              ? CredentialRefreshOutcome.uncertain
              : CredentialRefreshOutcome.busy;
        }
        if (response.ownerId != capability.ownerId ||
            response.endpoint != capability.endpoint) {
          return CredentialRefreshOutcome.uncertain;
        }
        final staged = await credentials.stage(response);
        await journal.markResponse(
          current.credentialId,
          staged,
          proposalId: proposalId,
        );
        if (!await credentials.replace(
          capability,
          expectedCredentialId: current.credentialId,
          stagedCredentialId: staged,
        )) {
          return CredentialRefreshOutcome.stale;
        }
        await journal.clear();
        await credentials.discardUnreferenced(current.credentialId);
        if (proposalId != null) {
          await credentials.discardUnreferenced(proposalId);
        }
        return CredentialRefreshOutcome.ready;
      });
    } on CredentialRefreshBusy {
      return CredentialRefreshOutcome.busy;
    }
  }
}
