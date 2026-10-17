import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { and, eq, sql } from 'drizzle-orm';
import { buildApp as buildApplication } from '../../app.js';
import { apiKeys, invitationTokens, outboxMessages, passwordResetTokens, users } from '../../db/schema.js';
import { createEncryptionCapabilities, sha256Hex } from '../../lib/crypto.js';
import {
  createDeliveryPayloadOpener,
  createDeliveryPayloadSealer,
} from '../../lib/delivery-payload-crypto.js';
import { RecoveryService } from '../../modules/recovery/recovery.service.js';
import type { SessionService } from '../../modules/auth/session.service.js';
import { buildTestConfig } from '../helpers/test-config.js';
import { createDbs, createUnclaimedKey, truncateAll } from '../helpers/db-helpers.js';
import { generateTestKeyPair } from '../helpers/key-helpers.js';
import type { Db } from '../../db/client.js';

const EMAIL = 'recovery-user@example.invalid';
const PASSWORD = 'original-password-123';
const NEW_PASSWORDS = ['reset-password-winner-123', 'reset-password-loser-456'];
const ENVELOPE_KEY = '1'.repeat(64);
const API_KEY_ENCRYPTION_KEY = '0'.repeat(64);
const PUBLIC_APP_URL = 'https://app.example.invalid/deep/link';

describe('password recovery and invitation workflows', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;
  let apiKey: string;
  const encryption = createEncryptionCapabilities(API_KEY_ENCRYPTION_KEY);
  const opener = createDeliveryPayloadOpener(ENVELOPE_KEY);
  const sealer = createDeliveryPayloadSealer(ENVELOPE_KEY);

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    const keys = generateTestKeyPair();
    const config = buildTestConfig({ privateKey: keys.privateKey, publicKey: keys.publicKey });
    config.publicAppUrl = PUBLIC_APP_URL;
    app = await buildApplication(config, {
      db: appDb,
      encryption: config.capabilities.totpCrypto,
      deliveryPayloadSealer: config.capabilities.deliveryPayloadSealer,
      deliverySubmitter: { submit: async () => undefined },
    }, {
      accessTokenTtlSeconds: 900,
      rateLimitMax: 100,
      forgotPasswordRateLimitMax: 100,
      logger: false,
    });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  beforeEach(async () => {
    await truncateAll(superDb);
    apiKey = await createUnclaimedKey(superDb);
  });

  async function registerAndLogin(): Promise<{ accessToken: string; refreshToken: string }> {
    const registered = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    expect(registered.statusCode).toBe(201);
    const login = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    expect(login.statusCode).toBe(200);
    return login.json();
  }

  async function requestReset(): Promise<{ token: string; tokenRowId: string }> {
    const requested = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/forgot-password',
      payload: { email: EMAIL },
    });
    expect(requested.statusCode).toBe(200);
    const [outbox] = await superDb
      .select()
      .from(outboxMessages)
      .where(eq(outboxMessages.messageType, 'password-reset'));
    expect(outbox).toBeDefined();
    const envelope = JSON.parse(opener.open(outbox!.encryptedDeliveryPayload!)) as { token: string };
    const [tokenRow] = await superDb
      .select()
      .from(passwordResetTokens)
      .where(eq(passwordResetTokens.tokenHash, sha256Hex(envelope.token)));
    expect(tokenRow).toBeDefined();
    return { token: envelope.token, tokenRowId: tokenRow!.id };
  }

  it('returns a neutral forgot-password response and stores only a hash plus encrypted delivery token', async () => {
    const unknown = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/forgot-password',
      payload: { email: 'not-registered@example.invalid' },
    });
    expect(unknown.statusCode).toBe(200);
    const noUserBody = unknown.json();
    expect(await superDb.select().from(passwordResetTokens)).toHaveLength(0);
    expect(await superDb.select().from(outboxMessages)).toHaveLength(0);

    await registerAndLogin();
    const [visibleUser] = await appDb
      .select({ id: users.id })
      .from(users)
      .where(eq(users.email, EMAIL));
    expect(visibleUser).toBeDefined();
    const known = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/forgot-password',
      payload: { email: EMAIL.toUpperCase() },
    });
    expect(known.statusCode).toBe(200);
    expect(known.json()).toEqual(noUserBody);

    const [tokenRow] = await superDb.select().from(passwordResetTokens);
    const [outbox] = await superDb.select().from(outboxMessages);
    expect(tokenRow).toBeDefined();
    expect(outbox).toMatchObject({ state: 'queued', messageType: 'password-reset', recipientRef: EMAIL });
    const envelope = JSON.parse(opener.open(outbox!.encryptedDeliveryPayload!)) as Record<string, unknown>;
    expect(Object.keys(envelope)).toEqual(['token']);
    expect(typeof envelope['token']).toBe('string');
    expect(envelope['token']).not.toBe(tokenRow!.tokenHash);
    expect(tokenRow!.tokenHash).toBe(sha256Hex(envelope['token'] as string));
    expect(outbox!.encryptedDeliveryPayload).not.toContain(envelope['token'] as string);
  });

  it('allows exactly one concurrent password reset and invalidates old access and refresh sessions', async () => {
    const oldSession = await registerAndLogin();
    const { token } = await requestReset();
    const attempts = await Promise.all(NEW_PASSWORDS.map((newPassword) => app.inject({
      method: 'POST',
      url: '/api/v1/auth/reset-password',
      payload: { token, newPassword },
    })));

    expect(attempts.map((result) => result.statusCode).sort()).toEqual([200, 400]);
    const winnerIndex = attempts.findIndex((result) => result.statusCode === 200);
    expect(attempts[1 - winnerIndex]!.json().code).toBe('AUTH_RESET_INVALID');

    const staleAccess = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { authorization: `Bearer ${oldSession.accessToken}`, 'x-api-key': apiKey },
    });
    const staleRefresh = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      headers: { 'x-api-key': apiKey },
      payload: { refreshToken: oldSession.refreshToken },
    });
    expect(staleAccess.statusCode).toBe(401);
    expect(staleRefresh.statusCode).toBe(401);

    const freshLogin = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password: NEW_PASSWORDS[winnerIndex] },
    });
    expect(freshLogin.statusCode).toBe(200);
  });

  it('rolls back reset-token consumption if session invalidation fails', async () => {
    await registerAndLogin();
    const { token, tokenRowId } = await requestReset();
    const failingSessions = {
      invalidateUserSessions: async () => { throw new Error('injected transaction failure'); },
    } as unknown as SessionService;
    const recovery = new RecoveryService(
      appDb,
      sealer,
      encryption,
      PUBLIC_APP_URL,
      failingSessions,
    );

    await expect(recovery.resetPassword(token, 'replacement-password-123'))
      .rejects.toMatchObject({ statusCode: 500, code: 'INTERNAL' });
    const [afterFailure] = await superDb
      .select()
      .from(passwordResetTokens)
      .where(eq(passwordResetTokens.id, tokenRowId));
    expect(afterFailure?.used).toBe(false);
  });

  it('atomically reveals a dedicated invitation key once, ignores spoofed proxy origins, and rejects replay', async () => {
    const rawApiKey = await createUnclaimedKey(superDb, 'recovery-invite-key');
    const [keyRow] = await superDb
      .select({ id: apiKeys.id, keyHash: apiKeys.keyHash })
      .from(apiKeys)
      .where(eq(apiKeys.keyHash, sha256Hex(rawApiKey)));
    expect(keyRow).toBeDefined();
    await superDb
      .update(apiKeys)
      .set({ encryptedKey: encryption.encrypt(rawApiKey) })
      .where(eq(apiKeys.id, keyRow!.id));

    const recovery = new RecoveryService(
      appDb,
      sealer,
      encryption,
      PUBLIC_APP_URL,
    );
    const privileges = await appDb.execute(sql`
      SELECT current_user AS role,
             has_column_privilege(current_user, 'public.invitation_tokens', 'token_hash', 'INSERT') AS can_insert_token,
             has_column_privilege(current_user, 'public.invitation_tokens', 'id', 'SELECT') AS can_return_id
    `) as Array<{ role: string; can_insert_token: boolean; can_return_id: boolean }>;
    expect(privileges[0]).toMatchObject({ role: 'app_user', can_insert_token: true, can_return_id: true });
    const created = await appDb.transaction((tx) =>
      recovery.createInvitation(tx, ' Invitee@Example.Invalid ', keyRow!.id));
    const [invitation] = await superDb
      .select()
      .from(invitationTokens)
      .where(eq(invitationTokens.id, created.invitationId));
    const [outbox] = await superDb
      .select()
      .from(outboxMessages)
      .where(and(eq(outboxMessages.messageType, 'invite'), eq(outboxMessages.recipientRef, 'invitee@example.invalid')));
    expect(invitation).toBeDefined();
    expect(outbox).toBeDefined();
    const deliveryEnvelope = JSON.parse(opener.open(outbox!.encryptedDeliveryPayload!)) as Record<string, unknown>;
    expect(Object.keys(deliveryEnvelope)).toEqual(['token']);
    expect(JSON.stringify(outbox)).not.toContain(rawApiKey);

    const rawInvitationToken = deliveryEnvelope['token'] as string;
    expect(invitation!.tokenHash).toBe(sha256Hex(rawInvitationToken));
    const headers = {
      host: 'attacker.example.invalid',
      'x-forwarded-host': 'attacker.example.invalid',
      'x-forwarded-proto': 'http',
    };
    const accept = () => app.inject({
      method: 'POST',
      url: '/api/v1/auth/invite/accept',
      headers,
      payload: { token: rawInvitationToken },
    });
    const results = await Promise.all([accept(), accept()]);
    expect(results.map((result) => result.statusCode).sort()).toEqual([200, 400]);
    const accepted = results.find((result) => result.statusCode === 200)!.json<{
      serverUrl: string;
      apiKey: string;
    }>();
    expect(accepted).toEqual({ serverUrl: 'https://app.example.invalid', apiKey: rawApiKey });

    const [clearedKey] = await superDb
      .select()
      .from(apiKeys)
      .where(eq(apiKeys.id, keyRow!.id));
    const [consumedInvitation] = await superDb
      .select()
      .from(invitationTokens)
      .where(eq(invitationTokens.id, created.invitationId));
    expect(clearedKey).toMatchObject({ keyHash: keyRow!.keyHash, encryptedKey: null, userId: null });
    expect(consumedInvitation?.consumedAt).toBeInstanceOf(Date);

    const replay = await accept();
    expect(replay.statusCode).toBe(400);
    expect(replay.json().code).toBe('AUTH_INVITATION_INVALID');
  });
});
