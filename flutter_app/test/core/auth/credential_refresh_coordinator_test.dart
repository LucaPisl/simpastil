import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/auth/credential_refresh_coordinator.dart';
import 'package:simpastil/core/auth/protected_credentials_repository.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

class _MemorySecrets implements CredentialSlotStore {
  final values = <String, String>{};
  bool failDurability = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
    if (failDurability) {
      throw StateError('Credential durability barrier failed');
    }
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late AppDatabase db;
  late Directory scratch;
  late WorkspaceAccessRepository access;
  late ProtectedCredentialsRepository credentials;
  late NetworkCapability capability;
  late String firstSlot;
  late _MemorySecrets secrets;
  final now = DateTime.utc(2026, 9, 30);
  CredentialBundle bundle(String marker, {bool expired = false}) =>
      CredentialBundle(
        ownerId: 'fictional-account',
        endpoint: 'https://fictional.test/care',
        accessToken: 'fictional-access-$marker',
        refreshToken: 'fictional-refresh-$marker',
        expiresAtMillis: now
            .add(
              expired ? const Duration(seconds: -1) : const Duration(hours: 1),
            )
            .millisecondsSinceEpoch,
      );
  NativeCredentialRefreshGate gate() => NativeCredentialRefreshGate(
    directory: scratch,
    syncDirectory: (_) async {},
  );
  CredentialRefreshCoordinator coordinator(
    Future<CredentialBundle> Function(CredentialBundle) request,
  ) => CredentialRefreshCoordinator(
    credentials: credentials,
    gate: gate(),
    request: request,
    clock: () => now,
  );
  setUp(() async {
    db = AppDatabase.forTesting();
    scratch = await Directory.systemTemp.createTemp('fictional-refresh-gate-');
    access = WorkspaceAccessRepository(db);
    credentials = ProtectedCredentialsRepository(
      access: access,
      store: secrets = _MemorySecrets(),
    );
    firstSlot = await credentials.stage(bundle('original', expired: true));
    final authenticated = await credentials.activate(
      credentialId: firstSlot,
      expectedTransition: await access.revokeNetwork(),
      sessionGeneration: 1,
    );
    capability = authenticated.network;
  });
  tearDown(() async {
    await db.close();
    await scratch.delete(recursive: true);
  });

  test(
    'failed credential durability prevents transmitting refresh proposal',
    () async {
      secrets.failDurability = true;
      var sent = false;
      final recovering = CredentialRefreshCoordinator(
        credentials: credentials,
        gate: gate(),
        clock: () => now,
        request: (_) async {
          sent = true;
          return bundle('wrong');
        },
        supportsRecovery: () async => true,
        requestRecoverable: (_, __) async {
          sent = true;
          return bundle('wrong');
        },
      );
      await expectLater(recovering.refresh(capability), throwsStateError);
      expect(sent, isFalse);
      expect(await gate().run((journal) => journal.currentAttempt()), isNull);
      expect((await credentials.readFor(capability))!.credentialId, firstSlot);
    },
  );

  test(
    'durable recovery keeps exact proposal through restart and a refused retry',
    () async {
      String? proposed;
      var sends = 0;
      var probes = 0;
      CredentialRefreshCoordinator recovering() => CredentialRefreshCoordinator(
        credentials: credentials,
        gate: gate(),
        clock: () => now,
        request: (_) => throw StateError('Legacy request must not run'),
        supportsRecovery: () async {
          probes++;
          return true;
        },
        requestRecoverable: (current, successor) async {
          proposed ??= successor;
          expect(successor, proposed);
          expect(current.refreshToken, 'fictional-refresh-original');
          sends++;
          if (sends == 1) throw StateError('Committed response lost');
          if (sends == 2) {
            throw const CredentialRefreshNotConsumed(
              CredentialRefreshOutcome.busy,
            );
          }
          return CredentialBundle(
            ownerId: current.ownerId,
            endpoint: current.endpoint,
            accessToken: 'fictional-recovered-access',
            refreshToken: successor,
            expiresAtMillis: now
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          );
        },
      );
      expect(
        await recovering().refresh(capability),
        CredentialRefreshOutcome.busy,
      );
      final first = await gate().run((j) => j.currentAttempt());
      expect(first?.proposalId, isNotNull);
      expect(
        await recovering().refresh(capability),
        CredentialRefreshOutcome.busy,
      );
      expect(
        (await gate().run((j) => j.currentAttempt()))?.proposalId,
        first?.proposalId,
      );
      expect(
        await recovering().refresh(capability),
        CredentialRefreshOutcome.ready,
      );
      expect(probes, 1);
      expect(sends, 3);
      expect(
        (await credentials.readFor(capability))!.bundle.refreshToken,
        proposed,
      );
      expect(await gate().run((j) => j.currentAttempt()), isNull);
    },
  );

  test(
    'interrupted next receipt preserves the valid durable proposal',
    () async {
      final proposal = await credentials.stage(
        bundle('proposal', expired: true),
      );
      await gate().run((j) => j.markSending(firstSlot, proposalId: proposal));
      await File(
        '${scratch.path}/refresh.next',
      ).writeAsString('{', flush: true);
      final pending = await gate().run((j) => j.currentAttempt());
      expect(pending?.proposalId, proposal);
      final c = CredentialRefreshCoordinator(
        credentials: credentials,
        gate: gate(),
        clock: () => now,
        request: (_) => throw StateError('Must not replay legacy'),
        requestRecoverable: (old, successor) async => CredentialBundle(
          ownerId: old.ownerId,
          endpoint: old.endpoint,
          accessToken: 'received',
          refreshToken: successor,
          expiresAtMillis: now
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        ),
      );
      expect(await c.refresh(capability), CredentialRefreshOutcome.ready);
    },
  );

  test('offline capability discovery never fences the unused token', () async {
    final c = CredentialRefreshCoordinator(
      credentials: credentials,
      gate: gate(),
      clock: () => now,
      request: (_) => throw StateError('Must not send'),
      requestRecoverable: (_, __) => throw StateError('Must not send'),
      supportsRecovery: () async => throw StateError('Offline'),
    );
    expect(await c.refresh(capability), CredentialRefreshOutcome.busy);
    expect(await gate().run((j) => j.currentAttempt()), isNull);
    expect((await credentials.readFor(capability))!.credentialId, firstSlot);
  });

  test(
    'a durably received response is published after restart without resending',
    () async {
      final response = await credentials.stage(bundle('received'));
      await gate().run((journal) async {
        await journal.markSending(firstSlot);
        await journal.markResponse(firstSlot, response);
      });
      expect(
        await coordinator(
          (_) => throw StateError('Must not resend'),
        ).refresh(capability),
        CredentialRefreshOutcome.ready,
      );
      expect((await credentials.readFor(capability))!.credentialId, response);
    },
  );

  test(
    'two gates serialize before token read and send a single refresh',
    () async {
      final sent = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      Future<CredentialBundle> request(CredentialBundle current) async {
        requests++;
        expect(current.refreshToken, 'fictional-refresh-original');
        sent.complete();
        await release.future;
        return bundle('renewed');
      }

      final first = coordinator(request).refresh(capability);
      await sent.future;
      final second = coordinator(request).refresh(capability);
      release.complete();
      expect(await first, CredentialRefreshOutcome.ready);
      expect(await second, CredentialRefreshOutcome.ready);
      expect(requests, 1);
      expect(
        (await credentials.readFor(capability))?.bundle.refreshToken,
        'fictional-refresh-renewed',
      );
    },
  );

  test(
    'interrupted uncertain attempt never resends its selected token',
    () async {
      await gate().run((journal) => journal.markSending(firstSlot));
      var requests = 0;
      final result = await coordinator((_) async {
        requests++;
        return bundle('unexpected');
      }).refresh(capability);
      expect(result, CredentialRefreshOutcome.uncertain);
      expect(requests, 0);
      expect(await access.contextForOwner(capability.ownerId), isNotNull);
      expect((await credentials.readFor(capability))?.credentialId, firstSlot);
    },
  );

  test(
    'transport failure preserves receipt, credentials and authorized offline care',
    () async {
      var requests = 0;
      final service = coordinator((_) async {
        requests++;
        throw const SocketException('fictional interrupted response');
      });
      expect(
        await service.refresh(capability),
        CredentialRefreshOutcome.uncertain,
      );
      expect(
        await service.refresh(capability),
        CredentialRefreshOutcome.uncertain,
      );
      expect(requests, 1);
      expect(await access.contextForOwner(capability.ownerId), isNotNull);
      expect((await credentials.readFor(capability))?.credentialId, firstSlot);
    },
  );

  test(
    'publication before receipt cleanup resumes from winning slot without replay',
    () async {
      await gate().run((journal) => journal.markSending(firstSlot));
      final winner = await credentials.stage(bundle('winning-refresh'));
      expect(
        await credentials.replace(
          capability,
          expectedCredentialId: firstSlot,
          stagedCredentialId: winner,
        ),
        isTrue,
      );
      var requests = 0;
      expect(
        await coordinator((_) async {
          requests++;
          return bundle('unexpected');
        }).refresh(capability),
        CredentialRefreshOutcome.ready,
      );
      expect(requests, 0);
      expect((await credentials.readFor(capability))?.credentialId, winner);
      expect(await gate().run((journal) => journal.currentAttempt()), isNull);
    },
  );

  test(
    'logout during refresh cannot reactivate credentials or connected care',
    () async {
      final sent = Completer<void>();
      final release = Completer<void>();
      final operation = coordinator((_) async {
        sent.complete();
        await release.future;
        return bundle('late');
      }).refresh(capability);
      await sent.future;
      await access.revokeNetwork();
      release.complete();
      expect(await operation, CredentialRefreshOutcome.stale);
      expect(await credentials.readFor(capability), isNull);
      expect(await access.contextForOwner(capability.ownerId), isNull);
      expect((await access.currentContext()).isLocal, isTrue);
    },
  );

  test(
    'explicit server rejection revokes only captured session and keeps its care',
    () async {
      expect(
        await coordinator((_) async {
          throw const CredentialRefreshRejected();
        }).refresh(capability),
        CredentialRefreshOutcome.rejected,
      );
      expect(await access.contextForOwner(capability.ownerId), isNull);
      expect(await access.workspaces.byOwner(capability.ownerId), isNotNull);
      expect((await access.currentContext()).isLocal, isTrue);
    },
  );

  test(
    'rejected refresh waits for another connection write then revokes',
    () async {
      await db.close();
      final file = File('${scratch.path}/fictional-care.db');
      db = AppDatabase(NativeDatabase(file));
      access = WorkspaceAccessRepository(db);
      credentials = ProtectedCredentialsRepository(
        access: access,
        store: secrets = _MemorySecrets(),
      );
      firstSlot = await credentials.stage(bundle('original', expired: true));
      capability = (await credentials.activate(
        credentialId: firstSlot,
        expectedTransition: await access.revokeNetwork(),
        sessionGeneration: 1,
      )).network;
      final writer = AppDatabase(NativeDatabase(file));
      await writer.customSelect('SELECT 1').get();
      final entered = Completer<void>();
      final release = Completer<void>();
      Future<void>? mutation;
      try {
        final renewal = coordinator((_) async {
          mutation = writer.transaction(() async {
            entered.complete();
            await release.future;
          });
          await entered.future;
          Timer(const Duration(milliseconds: 200), () => release.complete());
          throw const CredentialRefreshRejected();
        }).refresh(capability);
        expect(await renewal, CredentialRefreshOutcome.rejected);
        expect(await access.contextForOwner(capability.ownerId), isNull);
        expect((await access.currentContext()).isLocal, isTrue);
      } finally {
        if (!release.isCompleted) release.complete();
        await mutation;
        await writer.close();
      }
    },
  );

  test(
    'restart after definitive rejection resumes revocation without sending',
    () async {
      await gate().run((journal) => journal.markSending(firstSlot));
      // Simulates a flushed terminal response just before rename/publication.
      await File('${scratch.path}/refresh.next').writeAsString(
        '{"version":1,"state":"rejected","credentialId":"$firstSlot"}',
        flush: true,
      );
      var requests = 0;
      expect(
        await coordinator((_) async {
          requests++;
          return bundle('unexpected');
        }).refresh(capability),
        CredentialRefreshOutcome.rejected,
      );
      expect(requests, 0);
      expect(await access.contextForOwner(capability.ownerId), isNull);
      expect(await gate().run((journal) => journal.currentAttempt()), isNull);
    },
  );

  test(
    'journal retirement failure cannot publish a fresh access grant',
    () async {
      final fresh = await credentials.stage(bundle('fresh-login'));
      final transition = await access.revokeNetwork();
      final service = CredentialRefreshCoordinator(
        credentials: credentials,
        gate: NativeCredentialRefreshGate(
          directory: scratch,
          syncDirectory: (_) async {
            throw const FileSystemException(
              'fictional directory flush failure',
            );
          },
        ),
        request: (_) async => bundle('unexpected'),
      );
      await expectLater(
        service.activateFreshAuthentication(
          credentialId: fresh,
          expectedTransition: transition,
          sessionGeneration: 2,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await access.currentNetworkCapability(), isNull);
      expect(await access.contextForOwner(capability.ownerId), isNull);
    },
  );

  for (final interference in ['revoke', 'discard']) {
    test(
      'fresh publication refuses $interference during old-journal flush',
      () async {
        final fresh = await credentials.stage(bundle('fresh-login'));
        final transition = await access.revokeNetwork();
        var flushReached = false;
        final service = CredentialRefreshCoordinator(
          credentials: credentials,
          gate: NativeCredentialRefreshGate(
            directory: scratch,
            syncDirectory: (_) async {
              flushReached = true;
              if (interference == 'revoke') {
                await access.revokeNetwork();
              } else {
                await credentials.discardUnreferenced(fresh);
              }
            },
          ),
          request: (_) async => bundle('unexpected'),
        );
        await expectLater(
          service.activateFreshAuthentication(
            credentialId: fresh,
            expectedTransition: transition,
            sessionGeneration: 2,
          ),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        expect(flushReached, isTrue);
        expect(await access.currentNetworkCapability(), isNull);
      },
    );
  }

  test(
    'verified fresh login clears corrupt old receipt under the gate',
    () async {
      await File('${scratch.path}/refresh.json').writeAsString('{truncated');
      final fresh = await credentials.stage(
        bundle('fresh-login', expired: true),
      );
      final service = coordinator((_) async => bundle('renewed'));
      final newer = (await service.activateFreshAuthentication(
        credentialId: fresh,
        expectedTransition: await access.revokeNetwork(),
        sessionGeneration: 2,
      )).network;
      expect(await service.refresh(newer), CredentialRefreshOutcome.ready);
    },
  );

  test(
    'fresh login after uncertainty preserves pending care and legacy evidence',
    () async {
      final workspace = await access.workspaces.byOwner(capability.ownerId);
      await db
          .into(db.profiles)
          .insert(
            ProfilesCompanion.insert(
              id: 'fictional-pending-profile',
              userId: capability.ownerId,
              name: 'Fictional pending profile',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.pendingOperations)
          .insert(
            PendingOperationsCompanion.insert(
              id: 'fictional-pending-operation',
              userId: capability.ownerId,
              mutationId: 'fictional-mutation',
              component: 'medicationBridge',
              operationType: 'legacy.review',
              contractVersion: 1,
              payloadJson: '{"entityLocalId":"fictional-legacy-record"}',
              state: const Value('blocked'),
              attemptCount: const Value(1),
              createdAt: now,
            ),
          );
      await db
          .into(db.pendingOperationEffects)
          .insert(
            PendingOperationEffectsCompanion.insert(
              id: 'fictional-uncertain-effect',
              operationId: 'fictional-pending-operation',
              ordinal: 0,
              kind: 'dose',
              requestFingerprint: 'fictional-preserved-request',
              state: const Value('uncertain'),
              attemptedAt: Value(now),
            ),
          );
      await db
          .into(db.migrationIssues)
          .insert(
            MigrationIssuesCompanion.insert(
              id: 'fictional-review',
              userId: capability.ownerId,
              entityType: 'doseLog',
              entityId: 'fictional-legacy-record',
              issueCode: 'legacy_delivery_uncertain',
              snapshotJson: '{"history":"fictional-preserved-snapshot"}',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final profiles = await db.select(db.profiles).get();
      final operations = await db.select(db.pendingOperations).get();
      final effects = await db.select(db.pendingOperationEffects).get();
      final issues = await db.select(db.migrationIssues).get();
      var requests = 0;
      final service = coordinator((_) async {
        requests++;
        throw const SocketException('fictional lost response');
      });
      expect(
        await service.refresh(capability),
        CredentialRefreshOutcome.uncertain,
      );

      final fresh = await credentials.stage(bundle('fresh-login'));
      final transition = await access.revokeNetwork();
      expect(await access.contextForOwner(capability.ownerId), isNull);
      final recovered = await service.activateFreshAuthentication(
        credentialId: fresh,
        expectedTransition: transition,
        sessionGeneration: 2,
      );

      expect(recovered.workspace.id, workspace!.id);
      expect(
        await service.refresh(recovered.network),
        CredentialRefreshOutcome.ready,
      );
      expect(
        requests,
        1,
        reason: 'The ambiguous old token must never be replayed',
      );
      expect(await gate().run((journal) => journal.currentAttempt()), isNull);
      expect(
        (await credentials.readFor(recovered.network))?.credentialId,
        fresh,
      );
      expect(await access.contextForOwner(capability.ownerId), isNotNull);
      expect(await db.select(db.profiles).get(), profiles);
      expect(await db.select(db.pendingOperations).get(), operations);
      expect(await db.select(db.pendingOperationEffects).get(), effects);
      expect(await db.select(db.migrationIssues).get(), issues);
    },
  );

  for (final wrongIdentity in ['owner', 'endpoint']) {
    test(
      'refresh response with mismatched $wrongIdentity preserves uncertainty without replay',
      () async {
        var requests = 0;
        final service = coordinator((_) async {
          requests++;
          return CredentialBundle(
            ownerId: wrongIdentity == 'owner'
                ? 'fictional-other'
                : capability.ownerId,
            endpoint: wrongIdentity == 'endpoint'
                ? 'https://fictional-other.test/care'
                : capability.endpoint,
            accessToken: 'fictional-mismatched-access',
            refreshToken: 'fictional-mismatched-refresh',
            expiresAtMillis: now
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          );
        });

        expect(
          await service.refresh(capability),
          CredentialRefreshOutcome.uncertain,
        );
        expect(
          await service.refresh(capability),
          CredentialRefreshOutcome.uncertain,
        );
        expect(requests, 1);
        expect(
          (await credentials.readFor(capability))?.credentialId,
          firstSlot,
        );
        expect(await access.contextForOwner(capability.ownerId), isNotNull);
        expect(
          (await gate().run((journal) => journal.currentAttempt()))?.state,
          CredentialRefreshAttemptState.sending,
        );
      },
    );
  }

  test(
    'late fresh recovery cannot clear a consumed current slot receipt',
    () async {
      var requests = 0;
      final service = coordinator((_) async {
        requests++;
        throw const SocketException('fictional lost response');
      });
      final fresh = await credentials.stage(
        bundle('fresh-login', expired: true),
      );
      final transition = await access.revokeNetwork();
      final newer = (await service.activateFreshAuthentication(
        credentialId: fresh,
        expectedTransition: transition,
        sessionGeneration: 2,
      )).network;
      expect(await service.refresh(newer), CredentialRefreshOutcome.uncertain);
      await expectLater(
        service.activateFreshAuthentication(
          credentialId: fresh,
          expectedTransition: transition,
          sessionGeneration: 2,
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(
        (await gate().run((journal) => journal.currentAttempt()))?.credentialId,
        fresh,
      );
      expect(await service.refresh(newer), CredentialRefreshOutcome.uncertain);
      expect(requests, 1);
    },
  );

  test(
    'bounded revocation failure leaves rejection for a later process',
    () async {
      await db.close();
      final file = File('${scratch.path}/fictional-care.db');
      db = AppDatabase(NativeDatabase(file));
      access = WorkspaceAccessRepository(db);
      credentials = ProtectedCredentialsRepository(
        access: access,
        store: secrets = _MemorySecrets(),
      );
      firstSlot = await credentials.stage(bundle('original', expired: true));
      capability = (await credentials.activate(
        credentialId: firstSlot,
        expectedTransition: await access.revokeNetwork(),
        sessionGeneration: 1,
      )).network;
      final writer = AppDatabase(NativeDatabase(file));
      await writer.customSelect('SELECT 1').get();
      final entered = Completer<void>();
      final release = Completer<void>();
      Future<void>? mutation;
      try {
        await expectLater(
          coordinator((_) async {
            mutation = writer.transaction(() async {
              entered.complete();
              await release.future;
            });
            await entered.future;
            throw const CredentialRefreshRejected();
          }).refresh(capability),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        expect(
          (await gate().run((journal) => journal.currentAttempt()))?.state,
          CredentialRefreshAttemptState.rejected,
        );
        release.complete();
        await mutation;
        var requests = 0;
        expect(
          await coordinator((_) async {
            requests++;
            return bundle('unexpected');
          }).refresh(capability),
          CredentialRefreshOutcome.rejected,
        );
        expect(requests, 0);
        expect(await access.contextForOwner(capability.ownerId), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await mutation;
        await writer.close();
      }
    },
  );

  test(
    'corrupt receipt refuses renewal instead of silently clearing it',
    () async {
      final receipt = File('${scratch.path}/refresh.json');
      await receipt.writeAsString('{truncated');
      var requests = 0;
      await expectLater(
        coordinator((_) async {
          requests++;
          return bundle('unexpected');
        }).refresh(capability),
        throwsFormatException,
      );
      expect(requests, 0);
      expect(await receipt.readAsString(), '{truncated');
      expect((await credentials.readFor(capability))?.credentialId, firstSlot);
    },
  );
}
