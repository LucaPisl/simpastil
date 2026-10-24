import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { TOTP, Secret } from 'otpauth';
import type { FastifyInstance } from 'fastify';
import { sql } from 'drizzle-orm';
import { buildApp } from '../helpers/app-factory.js';
import { createApiKey, createDbs, createUnclaimedKey, truncateAll } from '../helpers/db-helpers.js';
import { createDeliveryPayloadOpener } from '../../lib/delivery-payload-crypto.js';
import { sha256Hex } from '../../lib/crypto.js';
import { ACCOUNT_EXPORT_EXCLUDED, ACCOUNT_EXPORT_TABLES } from '../../modules/account/account-export.js';

type Headers = Record<string, string>;
const PASSWORD = 'password1234';
let counter = 0;
const opener = createDeliveryPayloadOpener('1'.repeat(64));

describe('account self-service over the API', () => {
  let app: FastifyInstance;
  let noMailApp: FastifyInstance;
  let cleanup: () => Promise<void>;
  let superDb: Awaited<ReturnType<typeof createDbs>>['superDb'];

  interface Account { userId: string; email: string; key: string; headers: Headers }

  async function registerUser(target: FastifyInstance = app): Promise<Account> {
    const key = await createUnclaimedKey(superDb);
    const email = `self_${Date.now()}_${++counter}@test.com`;
    await target.inject({ method: 'POST', url: '/api/v1/auth/register', headers: { 'X-Api-Key': key }, payload: { email, password: PASSWORD } });
    const login = await target.inject({ method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': key }, payload: { email, password: PASSWORD } });
    const [row] = await superDb.execute<{ id: string }>(sql`SELECT id FROM users WHERE email = ${email}`);
    return {
      userId: row!.id, email, key,
      headers: { authorization: `Bearer ${login.json<{ accessToken: string }>().accessToken}`, 'X-Api-Key': key },
    };
  }

  /** One person, one medicine, one routine, one taken dose (legacy log) and one ledger take. */
  async function seedCare(userId: string): Promise<{ profileId: string; pillId: string; scheduleId: string }> {
    const profileId = randomUUID();
    const pillId = randomUUID();
    const scheduleId = randomUUID();
    await superDb.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      await tx.execute(sql`INSERT INTO profiles (id, user_id, name) VALUES (${profileId}, ${userId}, 'Ana')`);
      await tx.execute(sql`INSERT INTO pills (id, profile_id, name, current_stock) VALUES (${pillId}, ${profileId}, 'Vitamin D', 9)`);
      await tx.execute(sql`INSERT INTO schedules (id, pill_id, hour, minute, frequency, is_active, time_zone_status, time_zone)
        VALUES (${scheduleId}, ${pillId}, 8, 0, 'daily', true, 'known', 'Europe/Bucharest')`);
      await tx.execute(sql`INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status, updated_at)
        VALUES (${randomUUID()}, ${scheduleId}, '2026-10-01T05:00:00Z', '2026-10-01T05:00:00Z', 'taken', '2026-10-01T05:00:00Z')`);
      await tx.execute(sql`INSERT INTO account_settings (user_id, key, value, revision) VALUES (${userId}, 'language', '"ro"', 1) ON CONFLICT DO NOTHING`);
    });
    return { profileId, pillId, scheduleId };
  }

  async function enableTwoFactor(account: Account): Promise<string[]> {
    const setup = await app.inject({ method: 'POST', url: '/api/v1/auth/2fa/setup', headers: account.headers });
    const { secret } = setup.json<{ secret: string }>();
    const code = new TOTP({ issuer: 'Simpastil', label: account.email, secret: Secret.fromBase32(secret), digits: 6, period: 30 }).generate();
    const enabled = await app.inject({ method: 'POST', url: '/api/v1/auth/2fa/enable', headers: account.headers, payload: { code } });
    const backupCodes = enabled.json<{ backupCodes: string[] }>().backupCodes;
    // Turning 2FA on ends the old sign-in: sign in again with the last backup code.
    const login = await app.inject({ method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': account.key }, payload: { email: account.email, password: PASSWORD } });
    const { challengeToken } = login.json<{ challengeToken: string }>();
    const done = await app.inject({ method: 'POST', url: '/api/v1/auth/2fa/challenge', headers: { 'X-Api-Key': account.key }, payload: { challengeToken, code: backupCodes[7] } });
    account.headers = { authorization: `Bearer ${done.json<{ accessToken: string }>().accessToken}`, 'X-Api-Key': account.key };
    return backupCodes.slice(0, 7);
  }

  beforeAll(async () => {
    const dbs = createDbs();
    superDb = dbs.superDb;
    cleanup = dbs.cleanup;
    const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
    app = await buildApp({ db: dbs.appDb, ...keys, ttlSeconds: 600 });
    noMailApp = await buildApp({ db: dbs.appDb, ...keys, ttlSeconds: 600, smtpHost: '' });
  });
  afterEach(async () => truncateAll(superDb));
  afterAll(async () => {
    await app.close();
    await noMailApp.close();
    await cleanup();
  });

  const post = (url: string, headers: Headers, payload: unknown, target: FastifyInstance = app) =>
    target.inject({ method: 'POST', url, headers, payload: payload as object });
  const errorCode = (response: { json: <T>() => T }) => response.json<{ error: { code: string } }>().error.code;

  it('advertises the self-service contract and how an email change is confirmed', async () => {
    const withMail = (await app.inject({ method: 'GET', url: '/api/v1/capabilities' })).json<Record<string, unknown>>();
    expect((withMail['contracts'] as Record<string, number>)['accountSelfService']).toBe(1);
    expect(withMail['emailChange']).toBe('confirm');
    const withoutMail = (await noMailApp.inject({ method: 'GET', url: '/api/v1/capabilities' })).json<Record<string, unknown>>();
    expect(withoutMail['emailChange']).toBe('immediate');
  });

  describe('summary', () => {
    it('counts what the account holds and leaves other accounts out', async () => {
      const mine = await registerUser();
      await seedCare(mine.userId);
      const other = await registerUser();
      await seedCare(other.userId);
      await seedCare(other.userId);

      const response = await app.inject({ method: 'GET', url: '/api/v1/account/summary', headers: mine.headers });
      expect(response.statusCode).toBe(200);
      expect(response.json()).toEqual({
        email: mine.email,
        twoFactorEnabled: false,
        counts: { people: 1, medications: 1, routines: 1, doses: 1, inventoryEvents: 0, devices: 1, settings: 1 },
      });
    });

    it('needs a signed-in account', async () => {
      const response = await app.inject({ method: 'GET', url: '/api/v1/account/summary' });
      expect(response.statusCode).toBe(401);
    });
  });

  describe('delete', () => {
    it('refuses a wrong password with 400 and keeps the account and its sign-in', async () => {
      const account = await registerUser();
      const response = await post('/api/v1/account/delete', account.headers, { password: 'not-the-password' });
      expect(response.statusCode).toBe(400);
      expect(errorCode(response)).toBe('AUTH_INVALID_CREDENTIALS');
      const still = await app.inject({ method: 'GET', url: '/api/v1/account/summary', headers: account.headers });
      expect(still.statusCode).toBe(200);
    });

    it('asks for the 2FA code, rejects a wrong one, and accepts a backup code', async () => {
      const account = await registerUser();
      const backupCodes = await enableTwoFactor(account);
      const missing = await post('/api/v1/account/delete', account.headers, { password: PASSWORD });
      expect([missing.statusCode, errorCode(missing)]).toEqual([400, 'TOTP_REQUIRED']);
      const wrong = await post('/api/v1/account/delete', account.headers, { password: PASSWORD, code: '000000' });
      expect([wrong.statusCode, errorCode(wrong)]).toEqual([400, 'TOTP_INVALID_CODE']);
      const ok = await post('/api/v1/account/delete', account.headers, { password: PASSWORD, code: backupCodes[0] });
      expect(ok.statusCode).toBe(204);
    });

    it('removes every row of the account from every table, including an invitation tied to its key', async () => {
      const account = await registerUser();
      const bystander = await registerUser();
      await seedCare(account.userId);
      await seedCare(bystander.userId);
      const [keyRow] = await superDb.execute<{ id: string }>(sql`SELECT id FROM api_keys WHERE user_id = ${account.userId}`);
      await superDb.execute(sql`INSERT INTO invitation_tokens (token_hash, recipient_email, api_key_id, expires_at)
        VALUES (${'a'.repeat(64)}, 'invitee@example.invalid', ${keyRow!.id}, now() + interval '1 day')`);
      await app.inject({ method: 'PUT', url: '/api/v1/account/settings', headers: { ...account.headers, 'X-Simpastil-Client-Build': '9' },
        payload: { changes: [{ key: 'language', value: 'en', baseRevision: 1 }] } });

      const response = await post('/api/v1/account/delete', account.headers, { password: PASSWORD });
      expect(response.statusCode).toBe(204);

      const columns = await superDb.execute<{ table_name: string }>(sql`
        SELECT table_name FROM information_schema.columns
        WHERE table_schema = 'public' AND column_name = 'user_id'
          AND table_name IN (SELECT table_name FROM information_schema.tables WHERE table_type = 'BASE TABLE')`);
      expect(columns.length).toBeGreaterThan(8);
      for (const { table_name: table } of columns) {
        const [left] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM ${sql.identifier(table)} WHERE user_id = ${account.userId}`);
        expect([table, left!.n]).toEqual([table, 0]);
      }
      const [users] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM users WHERE id = ${account.userId}`);
      expect(users!.n).toBe(0);
      const [invites] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM invitation_tokens`);
      expect(invites!.n).toBe(0);
      // Nobody else lost anything.
      const summary = await app.inject({ method: 'GET', url: '/api/v1/account/summary', headers: bystander.headers });
      expect(summary.json<{ counts: { people: number } }>().counts.people).toBe(1);
    });

    it('answers ACCOUNT_DELETED to every device that still holds the account key', async () => {
      const account = await registerUser();
      const secondDevice = await createApiKey(superDb, account.userId, 'second');
      const response = await post('/api/v1/account/delete', account.headers, { password: PASSWORD });
      expect(response.statusCode).toBe(204);

      for (const key of [account.key, secondDevice]) {
        const verify = await app.inject({ method: 'GET', url: '/api/v1/auth/verify-key', headers: { 'X-Api-Key': key } });
        expect([verify.statusCode, verify.json<{ code: string }>().code]).toEqual([401, 'ACCOUNT_DELETED']);
        const guarded = await app.inject({ method: 'GET', url: '/api/v1/account/summary', headers: { ...account.headers, 'X-Api-Key': key } });
        expect([guarded.statusCode, guarded.json<{ code: string }>().code]).toEqual([401, 'ACCOUNT_DELETED']);
      }
      const stranger = await app.inject({ method: 'GET', url: '/api/v1/auth/verify-key', headers: { 'X-Api-Key': 'never-issued' } });
      expect(stranger.json<{ code: string }>().code).toBe('AUTH_KEY_INVALID');
    });

    it('tells a device that holds only the old refresh token the account is gone', async () => {
      const account = await registerUser();
      const login = await app.inject({ method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': account.key }, payload: { email: account.email, password: PASSWORD } });
      const { refreshToken } = login.json<{ refreshToken: string }>();
      // The second device has no key of this account; it signs its request with another account's key.
      const other = await registerUser();
      expect((await post('/api/v1/account/delete', account.headers, { password: PASSWORD })).statusCode).toBe(204);

      for (const url of ['/api/v1/auth/refresh', '/api/v1/auth/refresh/recoverable']) {
        const payload = url.endsWith('recoverable') ? { refreshToken, nextRefreshToken: 'a'.repeat(64) } : { refreshToken };
        const refreshed = await app.inject({ method: 'POST', url, headers: { 'X-Api-Key': other.key }, payload });
        expect([url, refreshed.statusCode, refreshed.json<{ code: string }>().code]).toEqual([url, 401, 'ACCOUNT_DELETED']);
      }
      const unknown = await app.inject({ method: 'POST', url: '/api/v1/auth/refresh', headers: { 'X-Api-Key': other.key }, payload: { refreshToken: 'f'.repeat(64) } });
      expect(unknown.json<{ code: string }>().code).not.toBe('ACCOUNT_DELETED');
    });

    it('does not mark a refresh token that was already rotated away', async () => {
      const account = await registerUser();
      const login = await app.inject({ method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': account.key }, payload: { email: account.email, password: PASSWORD } });
      const { refreshToken } = login.json<{ refreshToken: string }>();
      await app.inject({ method: 'POST', url: '/api/v1/auth/refresh', headers: { 'X-Api-Key': account.key }, payload: { refreshToken } });
      await post('/api/v1/account/delete', account.headers, { password: PASSWORD });
      const [old] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM deleted_account_markers WHERE key_hash = ${sha256Hex(refreshToken)}`);
      expect(old!.n).toBe(0);
    });

    it('drops unsent mail for the account but not other people\'s or mail in flight', async () => {
      const account = await registerUser();
      const other = await registerUser();
      const insert = (recipient: string, state: string) => superDb.execute(sql`
        INSERT INTO outbox_messages (message_type, recipient_ref, encrypted_delivery_payload, state, expires_at)
        VALUES ('email-change-notice', ${recipient}, 'x', ${state}, now() + interval '1 day')`);
      await insert(account.email, 'queued');
      await insert(account.email, 'retrying');
      await insert(account.email, 'sending');
      await insert(other.email, 'queued');
      await post('/api/v1/account/delete', account.headers, { password: PASSWORD });
      const rows = await superDb.execute<{ recipient_ref: string; state: string }>(sql`SELECT recipient_ref, state FROM outbox_messages ORDER BY state`);
      expect(rows.map((r) => [r.recipient_ref, r.state])).toEqual([
        [other.email, 'queued'],
        [account.email, 'sending'],
      ]);
    });

    it('lets only the signed-in owner clear outbox mail', async () => {
      const account = await registerUser();
      await expect(superDb.transaction(async (tx) => {
        await tx.execute(sql`SELECT set_config('app.current_user_id', ${randomUUID()}, true)`);
        await tx.execute(sql`SELECT public.delete_unsent_outbox_for_account(${account.userId}::uuid)`);
      })).rejects.toSatisfy((e: Error & { cause?: Error }) => /requires the signed-in owner/.test(`${e.message} ${e.cause?.message ?? ''}`));
    });

    it('forgets the marker after its retention and purges it', async () => {
      const account = await registerUser();
      await post('/api/v1/account/delete', account.headers, { password: PASSWORD });
      await superDb.execute(sql`UPDATE deleted_account_markers SET expires_at = now() - interval '1 second'`);
      const verify = await app.inject({ method: 'GET', url: '/api/v1/auth/verify-key', headers: { 'X-Api-Key': account.key } });
      expect(verify.json<{ code: string }>().code).toBe('AUTH_KEY_INVALID');
      await superDb.execute(sql`SELECT public.purge_deleted_account_markers()`);
      const [left] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM deleted_account_markers`);
      expect(left!.n).toBe(0);
    });

    it('stores only key hashes in the marker and no personal data in the audit entry', async () => {
      const account = await registerUser();
      await seedCare(account.userId);
      const live = await superDb.execute<{ token_hash: string }>(sql`SELECT token_hash FROM refresh_tokens WHERE user_id = ${account.userId} AND NOT revoked`);
      expect(live.length).toBeGreaterThan(0);
      await post('/api/v1/account/delete', account.headers, { password: PASSWORD });
      const markers = await superDb.execute<{ key_hash: string; kind: string }>(sql`SELECT key_hash, kind FROM deleted_account_markers`);
      expect(markers.filter((m) => m.kind === 'apiKey').map((m) => m.key_hash)).toEqual([sha256Hex(account.key)]);
      expect(markers.filter((m) => m.kind === 'refresh').map((m) => m.key_hash).sort()).toEqual(live.map((l) => l.token_hash).sort());
      for (const m of markers) expect(m.key_hash).toMatch(/^[0-9a-f]{64}$/);
      const [audit] = await superDb.execute<{ action: string; metadata: unknown }>(sql`SELECT action, metadata FROM audit_logs WHERE action = 'account.delete'`);
      expect(audit!.metadata).toEqual({ counts: { people: 1, medications: 1, routines: 1, doses: 1, inventoryEvents: 0, devices: 1, settings: 1 } });
      expect(JSON.stringify(audit)).not.toContain(account.email);
    });

    it('hides the marker table from the application role', async () => {
      const [role] = await superDb.execute<{ select: boolean; insert: boolean }>(sql`
        SELECT has_table_privilege('app_user', 'public.deleted_account_markers', 'SELECT') AS "select",
               has_table_privilege('app_user', 'public.deleted_account_markers', 'INSERT') AS "insert"`);
      expect(role).toEqual({ select: false, insert: false });
    });

    it('limits attempts', async () => {
      const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
      const dbs = createDbs();
      const limited = await buildApp({ db: dbs.appDb, ...keys, ttlSeconds: 600, rateLimitMax: 2 });
      try {
        const account = await registerUser(limited);
        const codes: number[] = [];
        for (let i = 0; i < 3; i += 1) codes.push((await post('/api/v1/account/delete', account.headers, { password: 'wrong-password' }, limited)).statusCode);
        expect(codes).toEqual([400, 400, 429]);
      } finally {
        await limited.close();
        await dbs.cleanup();
      }
    });
  });

  describe('export', () => {
    it('streams one JSON file with the account data and no secrets', async () => {
      const account = await registerUser();
      await seedCare(account.userId);
      const other = await registerUser();
      await seedCare(other.userId);

      const response = await app.inject({ method: 'GET', url: '/api/v1/account/export', headers: account.headers });
      expect(response.statusCode).toBe(200);
      expect(response.headers['content-type']).toContain('application/json');
      expect(response.headers['content-disposition']).toContain('attachment');
      const file = JSON.parse(response.body) as { format: string; version: number; account: Record<string, unknown>; tables: Record<string, Array<Record<string, unknown>>> };
      expect(file.format).toBe('simpastil-account-export');
      expect(file.version).toBe(1);
      expect(file.account).toMatchObject({ id: account.userId, email: account.email, twoFactorEnabled: false });
      expect(file.tables['profiles']).toHaveLength(1);
      expect(file.tables['profiles']![0]).toMatchObject({ name: 'Ana', userId: account.userId });
      expect(file.tables['pills']![0]).toMatchObject({ name: 'Vitamin D' });
      expect(file.tables['doseLogs']).toHaveLength(1);
      expect(file.tables['accountSettings']![0]).toMatchObject({ key: 'language', value: 'ro' });
      expect(file.tables['devices']).toHaveLength(1);
      expect(Object.keys(file.tables)).toEqual(ACCOUNT_EXPORT_TABLES.map((spec) => spec.key));

      const [hashes] = await superDb.execute<{ password_hash: string }>(sql`SELECT password_hash FROM users WHERE id = ${account.userId}`);
      for (const secret of [hashes!.password_hash, sha256Hex(account.key), 'passwordHash', 'keyHash', 'encryptedKey', 'totpSecret', 'tokenHash', other.userId]) {
        expect(response.body).not.toContain(secret);
      }
    });

    it('pages large tables without losing or repeating a row', async () => {
      const account = await registerUser();
      await superDb.execute(sql`INSERT INTO profiles (id, user_id, name)
        SELECT gen_random_uuid(), ${account.userId}, 'p' || g FROM generate_series(1, 2150) AS g`);
      const response = await app.inject({ method: 'GET', url: '/api/v1/account/export', headers: account.headers });
      const file = JSON.parse(response.body) as { tables: { profiles: Array<{ id: string }> } };
      expect(file.tables.profiles).toHaveLength(2150);
      expect(new Set(file.tables.profiles.map((row) => row.id)).size).toBe(2150);
    });

    it('covers every table: exported or excluded with a reason', async () => {
      const tables = await superDb.execute<{ table_name: string }>(sql`
        SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'`);
      const covered = new Set([...ACCOUNT_EXPORT_TABLES.map((spec) => spec.table), ...Object.keys(ACCOUNT_EXPORT_EXCLUDED)]);
      const missing = tables.map((t) => t.table_name).filter((name) => !covered.has(name) && !name.startsWith('__drizzle'));
      expect(missing).toEqual([]);
      for (const reason of Object.values(ACCOUNT_EXPORT_EXCLUDED)) expect(reason.length).toBeGreaterThan(3);
      const exported = new Set(ACCOUNT_EXPORT_TABLES.map((spec) => spec.table));
      for (const name of Object.keys(ACCOUNT_EXPORT_EXCLUDED)) expect(exported.has(name)).toBe(false);
    });

    it('records the export in the audit log and limits repeats', async () => {
      const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
      const dbs = createDbs();
      const limited = await buildApp({ db: dbs.appDb, ...keys, ttlSeconds: 600, rateLimitMax: 3 });
      try {
        const account = await registerUser(limited);
        for (let i = 0; i < 3; i += 1) {
          expect(await limited.inject({ method: 'GET', url: '/api/v1/account/export', headers: account.headers })).toHaveProperty('statusCode', 200);
        }
        const [audit] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM audit_logs WHERE action = 'account.export'`);
        expect(audit!.n).toBe(3);
        expect((await limited.inject({ method: 'GET', url: '/api/v1/account/export', headers: account.headers })).statusCode).toBe(429);
      } finally {
        await limited.close();
        await dbs.cleanup();
      }
    });
  });

  describe('change email', () => {
    const outbox = () => superDb.execute<{ message_type: string; recipient_ref: string; encrypted_delivery_payload: string }>(
      sql`SELECT message_type, recipient_ref, encrypted_delivery_payload FROM outbox_messages ORDER BY message_type`);

    it('with mail configured waits for the link, mails both addresses, and keeps every sign-in', async () => {
      const account = await registerUser();
      const newEmail = `  New_${account.email.toUpperCase()}  `;
      const response = await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail });
      expect(response.statusCode).toBe(200);
      expect(response.json()).toEqual({ status: 'confirmationSent' });

      const summary = await app.inject({ method: 'GET', url: '/api/v1/account/summary', headers: account.headers });
      expect(summary.json<{ email: string }>().email).toBe(account.email);

      const mails = await outbox();
      expect(mails.map((m) => [m.message_type, m.recipient_ref])).toEqual([
        ['email-change-confirm', `new_${account.email}`],
        ['email-change-notice', account.email],
      ]);
      expect(JSON.parse(opener.open(mails[1]!.encrypted_delivery_payload))).toEqual({});
      const { token } = JSON.parse(opener.open(mails[0]!.encrypted_delivery_payload)) as { token: string };

      const confirmed = await post('/api/v1/auth/change-email/confirm', {}, { token });
      expect(confirmed.statusCode).toBe(200);
      expect(confirmed.json()).toEqual({ status: 'changed' });
      const after = await app.inject({ method: 'GET', url: '/api/v1/account/summary', headers: account.headers });
      expect(after.statusCode).toBe(200);
      expect(after.json<{ email: string }>().email).toBe(`new_${account.email}`);

      const replay = await post('/api/v1/auth/change-email/confirm', {}, { token });
      expect([replay.statusCode, errorCode(replay)]).toEqual([400, 'AUTH_EMAIL_CHANGE_INVALID']);
      const login = await app.inject({ method: 'POST', url: '/api/v1/auth/login', headers: { 'X-Api-Key': account.key },
        payload: { email: `new_${account.email}`, password: PASSWORD } });
      expect(login.statusCode).toBe(200);
    });

    it('does not change anything until the link is opened, and an expired link does nothing', async () => {
      const account = await registerUser();
      await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: 'pending@example.com' });
      const [row] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM email_change_tokens WHERE user_id = ${account.userId}`);
      expect(row!.n).toBe(1);
      const { token } = JSON.parse(opener.open((await outbox())[0]!.encrypted_delivery_payload)) as { token: string };
      await superDb.execute(sql`UPDATE email_change_tokens SET expires_at = now() - interval '1 minute'`);
      const expired = await post('/api/v1/auth/change-email/confirm', {}, { token });
      expect([expired.statusCode, errorCode(expired)]).toEqual([400, 'AUTH_EMAIL_CHANGE_INVALID']);
      const [user] = await superDb.execute<{ email: string }>(sql`SELECT email FROM users WHERE id = ${account.userId}`);
      expect(user!.email).toBe(account.email);
    });

    it('lets a newer request replace the pending one', async () => {
      const account = await registerUser();
      await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: 'first@example.com' });
      await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: 'second@example.com' });
      const rows = await superDb.execute<{ new_email: string }>(sql`SELECT new_email FROM email_change_tokens`);
      expect(rows.map((r) => r.new_email)).toEqual(['second@example.com']);
    });

    it('refuses an address another account uses, on request and on confirmation', async () => {
      const account = await registerUser();
      const taken = await registerUser();
      const direct = await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: taken.email });
      expect([direct.statusCode, errorCode(direct)]).toEqual([409, 'AUTH_EMAIL_TAKEN']);

      await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: 'race@example.com' });
      const { token } = JSON.parse(opener.open((await outbox())[0]!.encrypted_delivery_payload)) as { token: string };
      await superDb.execute(sql`UPDATE users SET email = 'race@example.com' WHERE id = ${taken.userId}`);
      const confirm = await post('/api/v1/auth/change-email/confirm', {}, { token });
      expect([confirm.statusCode, errorCode(confirm)]).toEqual([409, 'AUTH_EMAIL_TAKEN']);
    });

    it('checks the password and the 2FA code before doing anything', async () => {
      const account = await registerUser();
      const wrong = await post('/api/v1/auth/change-email', account.headers, { password: 'nope-nope-nope', newEmail: 'x@example.com' });
      expect([wrong.statusCode, errorCode(wrong)]).toEqual([400, 'AUTH_INVALID_CREDENTIALS']);
      const backupCodes = await enableTwoFactor(account);
      const missing = await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: 'x@example.com' });
      expect([missing.statusCode, errorCode(missing)]).toEqual([400, 'TOTP_REQUIRED']);
      const ok = await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, code: backupCodes[0], newEmail: 'x@example.com' });
      expect(ok.statusCode).toBe(200);
      expect((await outbox()).length).toBe(2);
    });

    it('without mail applies at once, sends nothing and audits it', async () => {
      const account = await registerUser(noMailApp);
      const response = await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: 'Instant@Example.com' }, noMailApp);
      expect(response.json()).toEqual({ status: 'changed' });
      const [user] = await superDb.execute<{ email: string }>(sql`SELECT email FROM users WHERE id = ${account.userId}`);
      expect(user!.email).toBe('instant@example.com');
      expect(await outbox()).toHaveLength(0);
      const still = await noMailApp.inject({ method: 'GET', url: '/api/v1/account/summary', headers: account.headers });
      expect(still.statusCode).toBe(200);
      const [audit] = await superDb.execute<{ n: number }>(sql`SELECT count(*)::int AS n FROM audit_logs WHERE action = 'account.email_change'`);
      expect(audit!.n).toBe(1);
    });

    it('treats the same address as already done', async () => {
      const account = await registerUser();
      const response = await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: account.email.toUpperCase() });
      expect(response.json()).toEqual({ status: 'changed' });
      expect(await outbox()).toHaveLength(0);
    });

    const accountChanges = (userId: string) => superDb.execute<{ revision: string; email: string }>(sql`
      SELECT source_revision::text AS revision, payload->'payload'->>'email' AS email
      FROM sync_changes WHERE user_id = ${userId} AND entity_type = 'account' ORDER BY server_sequence`);

    it('sends the new address to every device with a revision that moves each time', async () => {
      const account = await registerUser(noMailApp);
      const before = await accountChanges(account.userId);
      expect(before.map((r) => r.email)).toEqual([account.email]);

      await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: 'one@example.com' }, noMailApp);
      await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: 'two@example.com' }, noMailApp);

      const after = await accountChanges(account.userId);
      expect(after.map((r) => r.email)).toEqual([account.email, 'one@example.com', 'two@example.com']);
      const revisions = after.map((r) => BigInt(r.revision));
      expect(revisions[1]!).toBeGreaterThan(revisions[0]!);
      expect(revisions[2]!).toBeGreaterThan(revisions[1]!);
    });

    it('keeps the account revision moving when a later sign-out-everywhere follows an email change', async () => {
      const account = await registerUser(noMailApp);
      await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: 'moved@example.com' }, noMailApp);
      const logout = await post('/api/v1/auth/logout-all', account.headers, {}, noMailApp);
      expect(logout.statusCode).toBe(204);
      const revisions = (await accountChanges(account.userId)).map((r) => BigInt(r.revision));
      expect(new Set(revisions).size).toBe(revisions.length);
    });

    it('ends password-reset links mailed before the change, in both modes', async () => {
      for (const [target, note] of [[noMailApp, 'no mail'], [app, 'mail']] as const) {
        const account = await registerUser(target);
        await superDb.execute(sql`INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
          VALUES (${account.userId}, ${`reset-${note}-${account.userId}`}, now() + interval '1 hour')`);
        const other = await registerUser(target);
        await superDb.execute(sql`INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
          VALUES (${other.userId}, ${`other-${note}-${other.userId}`}, now() + interval '1 hour')`);

        await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: `fresh-${note.replace(' ', '')}@example.com` }, target);
        if (target === app) {
          const { token } = JSON.parse(opener.open((await outbox())[0]!.encrypted_delivery_payload)) as { token: string };
          expect((await post('/api/v1/auth/change-email/confirm', {}, { token })).statusCode).toBe(200);
        }
        const mine = await superDb.execute(sql`SELECT 1 FROM password_reset_tokens WHERE user_id = ${account.userId}`);
        const theirs = await superDb.execute(sql`SELECT 1 FROM password_reset_tokens WHERE user_id = ${other.userId}`);
        expect([note, mine.length, theirs.length]).toEqual([note, 0, 1]);
      }
    });

    it('answers a wrong password or code before it says an address is in use', async () => {
      const account = await registerUser();
      const taken = await registerUser();
      const wrong = await post('/api/v1/auth/change-email', account.headers, { password: 'nope-nope-nope', newEmail: taken.email });
      expect([wrong.statusCode, errorCode(wrong)]).toEqual([400, 'AUTH_INVALID_CREDENTIALS']);
      await enableTwoFactor(account);
      const noCode = await post('/api/v1/auth/change-email', account.headers, { password: PASSWORD, newEmail: taken.email });
      expect([noCode.statusCode, errorCode(noCode)]).toEqual([400, 'TOTP_REQUIRED']);

      const instant = await registerUser(noMailApp);
      const instantTaken = await registerUser(noMailApp);
      const wrongInstant = await post('/api/v1/auth/change-email', instant.headers, { password: 'nope-nope-nope', newEmail: instantTaken.email }, noMailApp);
      expect([wrongInstant.statusCode, errorCode(wrongInstant)]).toEqual([400, 'AUTH_INVALID_CREDENTIALS']);
    });
  });
});
