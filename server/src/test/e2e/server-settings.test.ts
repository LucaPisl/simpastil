import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { eq, sql } from 'drizzle-orm';
import { buildApp } from '../helpers/app-factory.js';
import {
  createDbs,
  createUnclaimedKey,
  prepareBootstrapProof,
  truncateAll,
} from '../helpers/db-helpers.js';
import { auditLogs, outboxMessages, passwordResetTokens, users } from '../../db/schema.js';
import { sha256Hex } from '../../lib/crypto.js';
import type { Db } from '../../db/client.js';

const ADMIN_PASSWORD = 'adminpassword1234';
const EMAIL = 'settings-user@example.invalid';
const PASSWORD = 'original-password-123';

describe('server settings, reset links and email reset capability', () => {
  let app: FastifyInstance;
  let noSmtpApp: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
    app = await buildApp({ db: appDb, ...keys, ttlSeconds: 60 });
    noSmtpApp = await buildApp({ db: appDb, ...keys, ttlSeconds: 60, smtpHost: '' });
  });

  afterAll(async () => {
    await app.close();
    await noSmtpApp.close();
    await cleanup();
  });
  afterEach(async () => { await truncateAll(superDb); });

  async function adminToken(target: FastifyInstance = app): Promise<string> {
    const proof = await prepareBootstrapProof(superDb);
    await target.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'admin@test.com', password: ADMIN_PASSWORD, proof },
    });
    const res = await target.inject({
      method: 'POST', url: '/api/v1/admin/auth/login', payload: { password: ADMIN_PASSWORD },
    });
    return res.json().accessToken as string;
  }

  async function registerUser(): Promise<string> {
    const apiKey = await createUnclaimedKey(superDb);
    const res = await app.inject({
      method: 'POST', url: '/api/v1/auth/register',
      headers: { 'x-api-key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    expect(res.statusCode).toBe(201);
    return res.json().userId as string;
  }

  const put = (token: string, payload: unknown, target: FastifyInstance = app) => target.inject({
    method: 'PUT', url: '/api/v1/admin/settings',
    headers: { authorization: `Bearer ${token}` }, payload: payload as object,
  });

  const issueLink = (token: string, userId: string) => app.inject({
    method: 'POST', url: `/api/v1/admin/users/${userId}/reset-link`,
    headers: { authorization: `Bearer ${token}` },
  });

  const tokenFromLink = (link: string) => new URL(link.replace('/#/', '/')).searchParams.get('token')!;

  describe('settings table', () => {
    it('lets the API role read and update but never insert, delete or change the key', async () => {
      const privileges = await appDb.execute(sql`
        SELECT current_user AS role,
               has_table_privilege('public.server_settings', 'SELECT') AS can_select,
               has_table_privilege('public.server_settings', 'INSERT') AS can_insert,
               has_table_privilege('public.server_settings', 'DELETE') AS can_delete,
               has_table_privilege('public.server_settings', 'TRUNCATE') AS can_truncate,
               has_column_privilege('public.server_settings', 'password_reset_mode', 'UPDATE') AS can_update_mode,
               has_column_privilege('public.server_settings', 'singleton_key', 'UPDATE') AS can_update_key
      `) as Array<Record<string, unknown>>;
      expect(privileges[0]).toEqual({
        role: 'app_user', can_select: true, can_insert: false, can_delete: false,
        can_truncate: false, can_update_mode: true, can_update_key: false,
      });
      const flags = await superDb.execute(sql`
        SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'server_settings'
      `) as Array<{ relrowsecurity: boolean; relforcerowsecurity: boolean }>;
      expect(flags[0]).toEqual({ relrowsecurity: true, relforcerowsecurity: true });
      const outbox = await superDb.execute(sql`
        SELECT has_table_privilege('outbox_user', 'public.server_settings', 'SELECT') AS can_select
      `) as Array<{ can_select: boolean }>;
      expect(outbox[0]!.can_select).toBe(false);
    });

    it('enforces the single row and the lifetime range in the database', async () => {
      await expect(superDb.execute(sql`INSERT INTO server_settings (singleton_key) VALUES (false)`)).rejects.toThrow();
      await expect(superDb.execute(sql`UPDATE server_settings SET reset_link_lifetime_minutes = 4`)).rejects.toThrow();
      await expect(superDb.execute(sql`UPDATE server_settings SET reset_link_lifetime_minutes = 1441`)).rejects.toThrow();
      await expect(superDb.execute(sql`UPDATE server_settings SET password_reset_mode = 'both'`)).rejects.toThrow();
    });
  });

  describe('admin settings API', () => {
    it('requires the administrator', async () => {
      expect((await app.inject({ method: 'GET', url: '/api/v1/admin/settings' })).statusCode).toBe(401);
      expect((await app.inject({ method: 'PUT', url: '/api/v1/admin/settings', payload: { resetLinkLifetimeMinutes: 30 } })).statusCode).toBe(401);
      expect((await app.inject({ method: 'POST', url: '/api/v1/admin/users/00000000-0000-4000-8000-000000000000/reset-link' })).statusCode).toBe(401);
    });

    it('reports automatic defaults, updates validated fields and audits the change', async () => {
      const token = await adminToken();
      const initial = await app.inject({ method: 'GET', url: '/api/v1/admin/settings', headers: { authorization: `Bearer ${token}` } });
      expect(initial.statusCode).toBe(200);
      expect(initial.json()).toMatchObject({
        passwordResetMode: null, effectivePasswordResetMode: 'email',
        resetLinkLifetimeMinutes: 60, smtpConfigured: true,
      });

      for (const bad of [
        { resetLinkLifetimeMinutes: 4 }, { resetLinkLifetimeMinutes: 1441 },
        { resetLinkLifetimeMinutes: 10.5 }, { passwordResetMode: 'sms' }, {}, { unknown: true },
      ]) {
        const res = await put(token, bad);
        expect(res.statusCode, JSON.stringify(bad)).toBe(400);
      }

      const updated = await put(token, { passwordResetMode: 'manual', resetLinkLifetimeMinutes: 15 });
      expect(updated.statusCode).toBe(200);
      expect(updated.json()).toMatchObject({
        passwordResetMode: 'manual', effectivePasswordResetMode: 'manual', resetLinkLifetimeMinutes: 15,
      });
      const back = await put(token, { passwordResetMode: null });
      expect(back.json()).toMatchObject({ passwordResetMode: null, effectivePasswordResetMode: 'email', resetLinkLifetimeMinutes: 15 });

      const logs = await superDb.select().from(auditLogs).where(eq(auditLogs.action, 'settings.update'));
      expect(logs).toHaveLength(2);
      expect(logs.find((row) => (row.metadata as Record<string, unknown>)['passwordResetMode'] === 'manual')?.metadata)
        .toEqual({ passwordResetMode: 'manual', resetLinkLifetimeMinutes: 15 });
    });

    it('rejects email mode with a clear code when SMTP is not configured', async () => {
      const token = await adminToken(noSmtpApp);
      const view = await noSmtpApp.inject({ method: 'GET', url: '/api/v1/admin/settings', headers: { authorization: `Bearer ${token}` } });
      expect(view.json()).toMatchObject({ smtpConfigured: false, effectivePasswordResetMode: 'manual', passwordResetMode: null });
      const rejected = await put(token, { passwordResetMode: 'email' }, noSmtpApp);
      expect(rejected.statusCode).toBe(409);
      expect(rejected.json().code).toBe('ADMIN_EMAIL_RESET_UNAVAILABLE');
      expect((await put(token, { passwordResetMode: 'manual' }, noSmtpApp)).statusCode).toBe(200);
    });

    it('treats a stored email mode as manual when SMTP is not configured', async () => {
      await superDb.execute(sql`UPDATE server_settings SET password_reset_mode = 'email'`);
      const token = await adminToken(noSmtpApp);
      const view = await noSmtpApp.inject({ method: 'GET', url: '/api/v1/admin/settings', headers: { authorization: `Bearer ${token}` } });
      expect(view.json()).toMatchObject({ passwordResetMode: 'email', effectivePasswordResetMode: 'manual' });
    });
  });

  describe('capabilities emailReset', () => {
    const emailReset = async (target: FastifyInstance) =>
      (await target.inject({ method: 'GET', url: '/api/v1/capabilities' })).json().emailReset;

    it('is available only when the effective mode is email and SMTP is configured', async () => {
      expect(await emailReset(app)).toBe('available');
      await superDb.execute(sql`UPDATE server_settings SET password_reset_mode = 'manual'`);
      expect(await emailReset(app)).toBe('unavailable');
      await superDb.execute(sql`UPDATE server_settings SET password_reset_mode = 'email'`);
      expect(await emailReset(app)).toBe('available');
      expect(await emailReset(noSmtpApp)).toBe('unavailable');
    });

    it('exposes nothing per account', async () => {
      const body = (await app.inject({ method: 'GET', url: '/api/v1/capabilities' })).json() as Record<string, unknown>;
      expect(Object.keys(body).filter((key) => /mail|smtp|fail|user/i.test(key))).toEqual(['emailReset']);
    });
  });

  describe('reset links', () => {
    it('issues a one-time link once, no-store, usable once and absent from the audit log', async () => {
      const token = await adminToken();
      const userId = await registerUser();
      await put(token, { resetLinkLifetimeMinutes: 5 });
      const before = Date.now();
      const res = await issueLink(token, userId);
      expect(res.statusCode).toBe(200);
      expect(res.headers['cache-control']).toBe('no-store');
      const { link, expiresAt } = res.json<{ link: string; expiresAt: string }>();
      expect(link).toMatch(/^https?:\/\/[^/]+\/#\/reset-password\?token=[0-9a-f]{64}$/);
      const lifetimeMs = new Date(expiresAt).getTime() - before;
      expect(lifetimeMs).toBeGreaterThan(4 * 60_000);
      expect(lifetimeMs).toBeLessThanOrEqual(5 * 60_000 + 5_000);

      const rawToken = tokenFromLink(link);
      const [row] = await superDb.select().from(passwordResetTokens).where(eq(passwordResetTokens.userId, userId));
      expect(row!.tokenHash).toBe(sha256Hex(rawToken));
      expect(await superDb.select().from(outboxMessages)).toHaveLength(0);

      const logs = await superDb.select().from(auditLogs).where(eq(auditLogs.action, 'user.reset_link'));
      expect(logs).toHaveLength(1);
      expect(logs[0]!.targetId).toBe(userId);
      expect(JSON.stringify(logs[0])).not.toContain(rawToken);

      const reset = await app.inject({ method: 'POST', url: '/api/v1/auth/reset-password', payload: { token: rawToken, newPassword: 'brand-new-password-1' } });
      expect(reset.statusCode).toBe(200);
      const replay = await app.inject({ method: 'POST', url: '/api/v1/auth/reset-password', payload: { token: rawToken, newPassword: 'brand-new-password-2' } });
      expect(replay.statusCode).toBe(400);
    });

    it('revokes every earlier unused link when a new one is issued, by either path', async () => {
      const token = await adminToken();
      const userId = await registerUser();
      const first = tokenFromLink((await issueLink(token, userId)).json().link);
      const second = tokenFromLink((await issueLink(token, userId)).json().link);
      expect(await superDb.select().from(passwordResetTokens)).toHaveLength(1);
      const stale = await app.inject({ method: 'POST', url: '/api/v1/auth/reset-password', payload: { token: first, newPassword: 'brand-new-password-1' } });
      expect(stale.statusCode).toBe(400);

      await app.inject({ method: 'POST', url: '/api/v1/auth/forgot-password', payload: { email: EMAIL } });
      const rows = await superDb.select().from(passwordResetTokens);
      expect(rows).toHaveLength(1);
      expect(rows[0]!.tokenHash).not.toBe(sha256Hex(second));
      const outdated = await app.inject({ method: 'POST', url: '/api/v1/auth/reset-password', payload: { token: second, newPassword: 'brand-new-password-1' } });
      expect(outdated.statusCode).toBe(400);
    });

    it('applies the configured lifetime to emailed links', async () => {
      const token = await adminToken();
      await registerUser();
      await put(token, { resetLinkLifetimeMinutes: 1440 });
      await app.inject({ method: 'POST', url: '/api/v1/auth/forgot-password', payload: { email: EMAIL } });
      const [row] = await superDb.select().from(passwordResetTokens);
      const lifetime = row!.expiresAt.getTime() - Date.now();
      expect(lifetime).toBeGreaterThan(1439 * 60_000);
      expect(lifetime).toBeLessThanOrEqual(1440 * 60_000);
    });

    it('returns 404 for an unknown user and 400 for a malformed id', async () => {
      const token = await adminToken();
      expect((await issueLink(token, '00000000-0000-4000-8000-000000000000')).statusCode).toBe(404);
      expect((await issueLink(token, 'not-a-uuid')).statusCode).toBe(400);
    });
  });

  describe('manual mode', () => {
    it('answers forgot-password identically but creates nothing', async () => {
      const token = await adminToken();
      await registerUser();
      const emailBody = await app.inject({ method: 'POST', url: '/api/v1/auth/forgot-password', payload: { email: EMAIL } });
      expect(await superDb.select().from(passwordResetTokens)).toHaveLength(1);
      await superDb.delete(passwordResetTokens);
      await superDb.delete(outboxMessages);
      await put(token, { passwordResetMode: 'manual' });

      const known = await app.inject({ method: 'POST', url: '/api/v1/auth/forgot-password', payload: { email: EMAIL } });
      const unknown = await app.inject({ method: 'POST', url: '/api/v1/auth/forgot-password', payload: { email: 'nobody@example.invalid' } });
      expect(known.statusCode).toBe(200);
      expect(known.body).toBe(emailBody.body);
      expect(unknown.body).toBe(known.body);
      expect(await superDb.select().from(passwordResetTokens)).toHaveLength(0);
      expect(await superDb.select().from(outboxMessages)).toHaveLength(0);
      expect(await superDb.select({ id: users.id }).from(users)).toHaveLength(1);
    });

    it('refuses email invitations with a clear code but still issues manual links', async () => {
      const token = await adminToken();
      const userId = await registerUser();
      await put(token, { passwordResetMode: 'manual' });
      const invite = await app.inject({
        method: 'POST', url: '/api/v1/admin/invites',
        headers: { authorization: `Bearer ${token}` },
        payload: { email: 'invitee@example.invalid' },
      });
      expect(invite.statusCode).toBe(409);
      expect(invite.json().code).toBe('ADMIN_INVITE_EMAIL_UNAVAILABLE');
      expect(await superDb.select().from(outboxMessages)).toHaveLength(0);
      expect((await issueLink(token, userId)).statusCode).toBe(200);

      const key = await app.inject({
        method: 'POST', url: '/api/v1/admin/keys',
        headers: { authorization: `Bearer ${token}` }, payload: { label: 'manual onboarding' },
      });
      expect(key.statusCode).toBe(201);
    });
  });

  describe('email status', () => {
    const status = (token: string, target: FastifyInstance = app) => target.inject({
      method: 'GET', url: '/api/v1/admin/email-status', headers: { authorization: `Bearer ${token}` },
    });

    async function insertOutbox(state: string, ageDays: number, recipient: string): Promise<void> {
      await superDb.execute(sql`
        INSERT INTO outbox_messages (message_type, recipient_ref, state, expires_at, updated_at, safe_error_category)
        VALUES ('password-reset', ${recipient}, ${state}, now() + interval '1 day',
                now() - make_interval(days => ${ageDays}), ${state === 'failedPermanent' ? 'smtp_rejected' : null})
      `);
    }

    it('requires the administrator', async () => {
      expect((await app.inject({ method: 'GET', url: '/api/v1/admin/email-status' })).statusCode).toBe(401);
    });

    it('is empty on a clean install and reports the mode', async () => {
      const token = await adminToken();
      const res = await status(token);
      expect(res.statusCode).toBe(200);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(res.json()).toEqual({
        configured: true, effectiveMode: 'email', recentPermanentFailures: 0, lastPermanentFailureAt: null,
      });
      const noSmtp = await adminToken(noSmtpApp);
      expect((await status(noSmtp, noSmtpApp)).json()).toMatchObject({ configured: false, effectiveMode: 'manual' });
    });

    it('counts permanent failures from the last seven days without exposing recipients', async () => {
      const token = await adminToken();
      await insertOutbox('failedPermanent', 0, 'secret-recipient-one@example.invalid');
      await insertOutbox('failedPermanent', 3, 'secret-recipient-two@example.invalid');
      await insertOutbox('failedPermanent', 10, 'secret-recipient-old@example.invalid');
      await insertOutbox('sent', 0, 'secret-recipient-sent@example.invalid');
      const res = await status(token);
      const body = res.json();
      expect(body.recentPermanentFailures).toBe(2);
      expect(Date.now() - new Date(body.lastPermanentFailureAt).getTime()).toBeLessThan(60_000);
      expect(Object.keys(body).sort()).toEqual(['configured', 'effectiveMode', 'lastPermanentFailureAt', 'recentPermanentFailures']);
      expect(res.body).not.toContain('secret-recipient');
    });

    it('reports no last failure date when every failure is older than the window', async () => {
      const token = await adminToken();
      await insertOutbox('failedPermanent', 10, 'secret-recipient-old@example.invalid');
      const body = (await status(token)).json();
      expect(body.recentPermanentFailures).toBe(0);
      expect(body.lastPermanentFailureAt).toBeNull();
    });

    it('gives the API role the function but still no direct outbox access', async () => {
      const rows = await appDb.execute(sql`
        SELECT has_table_privilege('public.outbox_messages', 'SELECT') AS can_select,
               has_function_privilege('public.read_email_delivery_status(integer)', 'EXECUTE') AS can_execute
      `) as Array<{ can_select: boolean; can_execute: boolean }>;
      expect(rows[0]).toEqual({ can_select: false, can_execute: true });
      await insertOutbox('failedPermanent', 0, 'direct-read@example.invalid');
      expect(await appDb.execute(sql`SELECT count(*)::int AS n FROM public.outbox_messages`).catch(() => 'denied')).toBe('denied');
      const viaFunction = await appDb.execute(sql`SELECT * FROM public.read_email_delivery_status(7)`) as Array<Record<string, unknown>>;
      expect(Object.keys(viaFunction[0]!).sort()).toEqual(['last_permanent_failure_at', 'recent_permanent_failures']);
      const anonymous = await superDb.execute(sql`
        SELECT has_function_privilege('public', 'public.read_email_delivery_status(integer)', 'EXECUTE') AS can_execute
      `) as Array<{ can_execute: boolean }>;
      expect(anonymous[0]!.can_execute).toBe(false);
    });
  });
});
