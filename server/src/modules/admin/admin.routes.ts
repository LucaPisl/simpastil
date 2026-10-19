import rateLimit from '@fastify/rate-limit';
import { sql as drizzleSql } from 'drizzle-orm';
import { AdminService, AdminError } from './admin.service.js';
import { AuditService, FailedLoginAudit } from './audit.service.js';
import { AdminTotpService, TotpError } from '../auth/totp.service.js';
import {
  AdminSetupSchema, AdminLoginSchema, AdminRefreshSchema,
  CreateKeySchema, InviteSchema, ChangePasswordSchema, AdminAuditLogsQuerySchema, UpdateSettingsSchema, UserIdParamSchema,
} from './admin.schema.js';
import { SettingsError, SettingsService } from '../settings/settings.service.js';
import type { Db } from '../../db/client.js';
import { ErrorCode } from '../shared/errors.js';
import type { FastifyRequest, FastifyReply, FastifyInstance } from 'fastify';
import type { AppConfig } from '../../config/app-config.js';
import type { EncryptionCapabilities } from '../../lib/crypto.js';
import type { DeliveryPayloadSealer } from '../../lib/delivery-payload-crypto.js';
import { SessionService, parseSessionVersionClaim } from '../auth/session.service.js';
import { RecoveryService } from '../recovery/recovery.service.js';

function rateLimitError(_request: unknown, context: { statusCode: number; ttl: number }) {
  const err = new Error('Too Many Requests') as Error & { statusCode: number; code: string; retryAfter: number };
  err.statusCode = context.statusCode;
  err.code = ErrorCode.RATE_LIMIT_EXCEEDED;
  err.retryAfter = Math.ceil(context.ttl / 1000);
  return err;
}

declare module 'fastify' {
  interface FastifyInstance {
    adminGuard: (req: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
}

function sendAdminError(reply: FastifyReply, err: unknown): FastifyReply {
  if (err instanceof AdminError) return reply.status(err.statusCode).send({ error: err.message, code: err.code });
  throw err;
}

function sendSettingsError(reply: FastifyReply, err: unknown): FastifyReply {
  if (err instanceof SettingsError) return reply.status(err.statusCode).send({ error: err.message, code: err.code });
  throw err;
}

function sendTotpError(reply: FastifyReply, err: unknown): FastifyReply {
  if (err instanceof TotpError) return reply.status(err.statusCode).send({ error: err.message, code: err.code });
  throw err;
}

export default async function adminRoutes(fastify: FastifyInstance, opts: { db: Db; config: AppConfig & { role: 'api' | 'test' }; crypto: EncryptionCapabilities; payloadSealer: DeliveryPayloadSealer; rateLimitMax?: number; rateLimitTimeWindow?: string | number; ttlSeconds?: number; sessionService?: SessionService; settings?: SettingsService }) {
  const database = opts.db;
  const sessions = opts.sessionService ?? new SessionService(database, { environmentManagedAdmin: opts.config.admin !== undefined });
  const ttlSeconds = opts.ttlSeconds ?? opts.config.jwt.accessTokenTtlSeconds;

  const service = new AdminService(
    database,
    (sessionVersion = '1', sid?: string) => fastify.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion, ...(sid ? { sid } : {}) }, { expiresIn: ttlSeconds }),
    (sessionVersion = '1') => fastify.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion, purpose: '2fa-challenge' }, { expiresIn: 300 }),
    opts.crypto,
    opts.config.admin ? { credentials: opts.config.admin } : {},
    sessions,
  );
  const audit = new AuditService(database);
  const failedLogins = new FailedLoginAudit(audit);
  const adminTotp = new AdminTotpService(database, opts.crypto, sessions);
  const settings = opts.settings ?? new SettingsService(database, opts.config.smtpConfigured);
  const recovery = new RecoveryService(database, opts.payloadSealer, opts.crypto, opts.config.publicAppUrl, sessions, settings);

  function clientIp(req: FastifyRequest): string | null {
    return req.ip ?? null;
  }

  /**
   * Verifies an admin access token and says which sign-in it belongs to.
   * Returns null for anything that is not a valid admin access token. `live`
   * is false when the token names a sign-in (`sid`, its refresh family) that
   * has since been ended. Tokens minted before `sid` existed carry no
   * sign-in and stay valid until their short expiry.
   */
  async function verifyAdminToken(req: FastifyRequest): Promise<{ sid?: string; live: boolean } | null> {
    try {
      await req.jwtVerify();
      const payload = req.user as unknown as {
        sub: string;
        role?: unknown;
        exp?: unknown;
        sessionVersion?: unknown;
        purpose?: unknown;
        sid?: unknown;
      };
      // Security, token purpose: challenge JWTs use the same signing key
      // as admin access JWTs. Reject every own purpose property, regardless of
      // value; only a token with no purpose property can reach admin data.
      if (Object.prototype.hasOwnProperty.call(payload, 'purpose')
          || payload.sub !== 'admin'
          || payload.role !== 'admin'
          || typeof payload.exp !== 'number'
          || !Number.isFinite(payload.exp)
          || parseSessionVersionClaim(payload.sessionVersion) === null
          || !await sessions.assertAdminSession(payload.sessionVersion)) {
        return null;
      }
      if (!Object.prototype.hasOwnProperty.call(payload, 'sid')) return { live: true };
      if (typeof payload.sid !== 'string') return null;
      return { sid: payload.sid, live: await sessions.isAdminSessionLive(payload.sid) };
    } catch {
      return null;
    }
  }

  // adminGuard — registered in this scope, used only by routes in this plugin
  fastify.decorate('adminGuard', async (req: FastifyRequest, reply: FastifyReply) => {
    const session = await verifyAdminToken(req);
    if (!session || !session.live) {
      return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.ADMIN_UNAUTHORIZED });
    }
  });

  // ── Setup (unguarded, rate limited) ─────────────────────────────────────────
  await fastify.register(async (setupScope) => {
    await setupScope.register(rateLimit, {
      max: opts.rateLimitMax ?? 5,
      timeWindow: opts.rateLimitTimeWindow ?? '15 minutes',
      errorResponseBuilder: rateLimitError,
    });

    setupScope.post('/admin/setup', async (request, reply) => {
      const body = AdminSetupSchema.parse(request.body);
      try {
        await service.setup(body.email, body.password, body.proof);
        await audit.log('admin', 'admin.login', 'admin', null, clientIp(request), { event: 'initial_setup' });
        return reply.status(201).send({ ok: true });
      } catch (err) { return sendAdminError(reply, err); }
    });
  });

  // ── Status (unguarded) ────────────────────────────────────────────────────
  fastify.get('/admin/status', async (_req, reply) => {
    const configured = await service.isAdminConfigured();
    return reply.status(200).send({ configured });
  });

  // ── Admin auth (login rate limited) ───────────────────────────────────────
  await fastify.register(async (scope) => {
    await scope.register(rateLimit, { max: opts.rateLimitMax ?? 5, timeWindow: opts.rateLimitTimeWindow ?? '15 minutes', errorResponseBuilder: rateLimitError });

    scope.post('/admin/auth/login', async (request, reply) => {
      const body = AdminLoginSchema.parse(request.body);
      try {
        const result = await service.login(body.password);
        await audit.log('admin', 'admin.login', 'admin', null, clientIp(request));
        return reply.status(200).send(result);
      } catch (err) {
        if (err instanceof AdminError && err.code === ErrorCode.ADMIN_INVALID_CREDENTIALS) {
          await failedLogins.record(clientIp(request));
        }
        return sendAdminError(reply, err);
      }
    });
  });

  await fastify.register(async (refreshScope) => {
    await refreshScope.register(rateLimit, {
      max: 20,
      timeWindow: opts.rateLimitTimeWindow ?? '5 minutes',
      errorResponseBuilder: rateLimitError,
    });

    refreshScope.post('/admin/auth/refresh', async (request, reply) => {
      const body = AdminRefreshSchema.parse(request.body);
      try {
        return reply.status(200).send(await service.refresh(body.refreshToken));
      } catch (err) { return sendAdminError(reply, err); }
    });
  });

  fastify.post('/admin/auth/change-password', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { newPassword } = ChangePasswordSchema.parse(request.body);
    try {
      await service.changePassword(newPassword);
      await audit.log('admin', 'admin.password_change', 'admin', null, clientIp(request));
      return reply.status(200).send({ ok: true });
    } catch (err) { return sendAdminError(reply, err); }
  });

  // Signs out this one browser. The guard is the token check alone, not the
  // liveness check, so repeating the call after the sign-in has ended is a
  // quiet 204 rather than a 401.
  fastify.post('/admin/auth/logout', async (request, reply) => {
    const session = await verifyAdminToken(request);
    if (!session) return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.ADMIN_UNAUTHORIZED });
    await service.logout(session.sid);
    await audit.log('admin', 'admin.logout', 'admin', null, clientIp(request));
    return reply.status(204).send();
  });

  fastify.post('/admin/auth/logout-all', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    try {
      await service.logoutAll();
      await audit.log('admin', 'admin.logout_all', 'admin', null, clientIp(request));
      return reply.status(204).send();
    } catch (err) { return sendAdminError(reply, err); }
  });

  // ── Admin 2FA ──────────────────────────────────────────────────────────────

  fastify.get('/admin/auth/2fa/status', { preHandler: [fastify.adminGuard] }, async (_request, reply) => {
    return reply.header('Cache-Control', 'no-store').status(200).send(await adminTotp.status());
  });

  fastify.post('/admin/auth/2fa/setup', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    try {
      const result = await adminTotp.setup();
      return reply.header('Cache-Control', 'no-store').status(200).send(result);
    } catch (err) { return sendTotpError(reply, err); }
  });

  fastify.post('/admin/auth/2fa/enable', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { code } = (request.body as { code?: string }) ?? {};
    if (!code) return reply.status(400).send({ error: 'code is required', code: ErrorCode.VALIDATION_ERROR });
    try {
      const result = await adminTotp.enable(code);
      await audit.log('admin', 'admin.2fa_enable', 'admin', null, clientIp(request));
      return reply.header('Cache-Control', 'no-store').status(200).send(result);
    } catch (err) { return sendTotpError(reply, err); }
  });

  fastify.post('/admin/auth/2fa/disable', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { code } = (request.body as { code?: string }) ?? {};
    if (!code) return reply.status(400).send({ error: 'code is required', code: ErrorCode.VALIDATION_ERROR });
    try {
      await adminTotp.disable(code);
      await audit.log('admin', 'admin.2fa_disable', 'admin', null, clientIp(request));
      return reply.status(200).send({ ok: true });
    } catch (err) { return sendTotpError(reply, err); }
  });

  fastify.post('/admin/auth/2fa/backup-codes', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { code } = (request.body as { code?: string }) ?? {};
    if (!code) return reply.status(400).send({ error: 'code is required', code: ErrorCode.VALIDATION_ERROR });
    try {
      const result = await adminTotp.regenerateBackupCodes(code);
      await audit.log('admin', 'admin.2fa_backup_codes', 'admin', null, clientIp(request));
      return reply.header('Cache-Control', 'no-store').status(200).send(result);
    } catch (err) { return sendTotpError(reply, err); }
  });

  // ── Admin 2FA challenge — rate limited: 5 attempts per IP per 5 minutes (H-3)
  await fastify.register(async (challengeScope) => {
    await challengeScope.register(rateLimit, {
      max: opts.rateLimitMax ?? 5,
      timeWindow: opts.rateLimitTimeWindow ?? '5 minutes',
      errorResponseBuilder: rateLimitError,
    });

    challengeScope.post('/admin/auth/2fa/challenge', async (request, reply) => {
      const { challengeToken, code } = (request.body as { challengeToken?: string; code?: string }) ?? {};
      if (!challengeToken || !code) {
        return reply.status(400).send({ error: 'challengeToken and code are required', code: ErrorCode.VALIDATION_ERROR });
      }
      try {
        const payload = fastify.jwt.verify<{
          sub: string;
          role?: unknown;
          purpose?: unknown;
          sessionVersion?: unknown;
          exp?: unknown;
        }>(challengeToken);
        if (!Object.prototype.hasOwnProperty.call(payload, 'purpose')
            || payload.purpose !== '2fa-challenge'
            || payload.sub !== 'admin'
            || payload.role !== 'admin'
            || typeof payload.exp !== 'number'
            || !Number.isFinite(payload.exp)
            || parseSessionVersionClaim(payload.sessionVersion) === null
            || !await sessions.assertAdminSession(payload.sessionVersion)) {
          return reply.status(400).send({ error: 'Invalid challenge token', code: ErrorCode.TOTP_CHALLENGE_INVALID });
        }
        await adminTotp.verifyChallenge(code);
        const result = await service.issueTokens(parseSessionVersionClaim(payload.sessionVersion)!.toString(10));
        await audit.log('admin', 'admin.login', 'admin', null, clientIp(request), { via: '2fa' });
        return reply.status(200).send(result);
      } catch (err) {
        if (err instanceof TotpError) {
          if (err.code === ErrorCode.TOTP_INVALID_CODE) await failedLogins.record(clientIp(request));
          return sendTotpError(reply, err);
        }
        return reply.status(400).send({ error: 'Invalid or expired challenge token', code: ErrorCode.TOTP_CHALLENGE_INVALID });
      }
    });
  });

  // ── Keys ───────────────────────────────────────────────────────────────────
  fastify.get('/admin/keys', { preHandler: [fastify.adminGuard] }, async (_req, reply) => {
    return reply.status(200).send({ keys: await service.listKeys() });
  });

  fastify.post('/admin/keys', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const body = CreateKeySchema.parse(request.body);
    try {
      const result = await database.transaction(async (tx) => {
        const r = await service.createKey(body.label, undefined, tx);
        await audit.log('admin', 'key.create', 'api_key', r.keyId, clientIp(request), { label: body.label }, tx);
        return r;
      });
      return reply.status(201).send(result);
    } catch (err) { return sendAdminError(reply, err); }
  });

  fastify.get('/admin/keys/:id/reveal', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const rawKey = await service.revealKey(id);
    await audit.log('admin', 'key.reveal', 'api_key', id, clientIp(request));
    if (rawKey === null) {
      return reply.status(200).send({ rawKey: null });
    }
    return reply.status(200).send({ rawKey });
  });

  fastify.delete('/admin/keys/:id', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    await database.transaction(async (tx) => {
      await service.revokeKey(id, tx);
      await audit.log('admin', 'key.revoke', 'api_key', id, clientIp(request), undefined, tx);
    });
    return reply.status(204).send();
  });

  fastify.post('/admin/invites', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const body = InviteSchema.parse(request.body);
    try {
      if (!await recovery.invitationEmailAvailable()) {
        return reply.status(409).send({
          error: 'Email invitations are unavailable while password reset is in manual mode. Create an API key instead.',
          code: ErrorCode.ADMIN_INVITE_EMAIL_UNAVAILABLE,
        });
      }
      const keyId = await database.transaction(async (tx) => {
        const key = await service.createInviteKey(body.label ?? `Invite for ${body.email}`, tx);
        await recovery.createInvitation(tx, body.email, key.keyId);
        await audit.log('admin', 'key.invite', 'api_key', key.keyId, clientIp(request), { email: body.email }, tx);
        return key.keyId;
      });
      return reply.status(202).send({ keyId, status: 'queued' });
    } catch (err) { return sendAdminError(reply, err); }
  });

  // ── User keys ─────────────────────────────────────────────────────────────
  fastify.get('/admin/users/:id/keys', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    return reply.status(200).send({ keys: await service.listUserKeys(id) });
  });

  fastify.post('/admin/users/:id/keys', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const body = CreateKeySchema.parse(request.body);
    try {
      const result = await database.transaction(async (tx) => {
        const r = await service.createKey(body.label, id, tx);
        await audit.log('admin', 'key.create', 'api_key', r.keyId, clientIp(request), { label: body.label, userId: id }, tx);
        return r;
      });
      return reply.status(201).send(result);
    } catch (err) { return sendAdminError(reply, err); }
  });

  // ── Users ──────────────────────────────────────────────────────────────────
  fastify.get('/admin/users', { preHandler: [fastify.adminGuard] }, async (_req, reply) => {
    return reply.status(200).send({ users: await service.listUsers() });
  });

  fastify.get('/admin/users/:id/devices', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    return reply.status(200).send({ devices: await service.listDevices(id) });
  });

  fastify.delete('/admin/users/:id/devices/:familyId', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { id, familyId } = request.params as { id: string; familyId: string };
    const affected = await database.transaction(async (tx) => {
      const n = await service.logoutDevice(id, familyId, tx);
      if (n > 0) {
        // Reset RLS context before audit write — logoutDevice sets it to the
        // target user, but audit_logs has no RLS so this is defensive.
        await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', '', true)`);
        await audit.log('admin', 'device.logout', 'device', familyId, clientIp(request), { userId: id }, tx);
      }
      return n;
    });
    if (affected === 0) return reply.status(404).send({ error: 'Device not found', code: ErrorCode.RESOURCE_NOT_FOUND });
    return reply.status(204).send();
  });

  // The one-time reset link is returned exactly once, never stored in
  // plain text and never written to the audit log.
  await fastify.register(async (resetLinkScope) => {
    await resetLinkScope.register(rateLimit, {
      max: opts.rateLimitMax ?? 20,
      timeWindow: opts.rateLimitTimeWindow ?? '15 minutes',
      errorResponseBuilder: rateLimitError,
    });
    resetLinkScope.post('/admin/users/:id/reset-link', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
      const { id } = UserIdParamSchema.parse(request.params);
      const issued = await database.transaction(async (tx) => {
        const result = await recovery.issueManualResetLink(id, tx);
        if (!result) return null;
        await tx.execute(drizzleSql`SELECT set_config('app.current_user_id', '', true)`);
        await audit.log('admin', 'user.reset_link', 'user', id, clientIp(request), {
          expiresAt: result.expiresAt.toISOString(),
        }, tx);
        return result;
      });
      if (!issued) return reply.status(404).send({ error: 'User not found', code: ErrorCode.RESOURCE_NOT_FOUND });
      return reply
        .header('Cache-Control', 'no-store')
        .header('Pragma', 'no-cache')
        .status(200)
        .send({ link: issued.link, expiresAt: issued.expiresAt.toISOString() });
    });
  });

  fastify.delete('/admin/users/:id', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const affected = await database.transaction(async (tx) => {
      const n = await service.deleteUser(id, tx);
      if (n > 0) await audit.log('admin', 'user.delete', 'user', id, clientIp(request), undefined, tx);
      return n;
    });
    if (affected === 0) return reply.status(404).send({ error: 'User not found', code: ErrorCode.RESOURCE_NOT_FOUND });
    return reply.status(204).send();
  });

  // ── Settings ───────────────────────────────────────────────────────────────
  const settingsView = (view: Awaited<ReturnType<SettingsService['get']>>) => ({
    passwordResetMode: view.passwordResetMode,
    effectivePasswordResetMode: view.effectivePasswordResetMode,
    resetLinkLifetimeMinutes: view.resetLinkLifetimeMinutes,
    smtpConfigured: view.smtpConfigured,
    updatedAt: view.updatedAt ? view.updatedAt.toISOString() : null,
  });

  fastify.get('/admin/settings', { preHandler: [fastify.adminGuard] }, async (_req, reply) => {
    return reply.status(200).send(settingsView(await settings.get()));
  });

  fastify.put('/admin/settings', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const body = UpdateSettingsSchema.parse(request.body);
    try {
      const view = await database.transaction(async (tx) => {
        const updated = await settings.update({
          ...(body.passwordResetMode === undefined ? {} : { passwordResetMode: body.passwordResetMode }),
          ...(body.resetLinkLifetimeMinutes === undefined ? {} : { resetLinkLifetimeMinutes: body.resetLinkLifetimeMinutes }),
        }, tx);
        await audit.log('admin', 'settings.update', 'settings', null, clientIp(request), {
          ...(body.passwordResetMode === undefined ? {} : { passwordResetMode: body.passwordResetMode }),
          ...(body.resetLinkLifetimeMinutes === undefined ? {} : { resetLinkLifetimeMinutes: body.resetLinkLifetimeMinutes }),
        }, tx);
        return updated;
      });
      return reply.status(200).send(settingsView(view));
    } catch (err) { return sendSettingsError(reply, err); }
  });

  // Delivery health for the console card: counts only, never recipients.
  fastify.get('/admin/email-status', { preHandler: [fastify.adminGuard] }, async (_req, reply) => {
    return reply.header('Cache-Control', 'no-store').status(200).send(await settings.emailStatus());
  });

  // ── Audit logs ──────────────────────────────────────────────────────────────
  fastify.get('/admin/audit-logs', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { limit, offset, action, from, to } = AdminAuditLogsQuerySchema.parse(request.query);
    const { entries, hasMore } = await audit.list({
      limit: limit ?? 50,
      offset: offset ?? 0,
      action,
      from: from ? new Date(from) : undefined,
      to: to ? new Date(to) : undefined,
    });
    return reply.header('Cache-Control', 'no-store').status(200).send({ logs: entries, hasMore });
  });
}
