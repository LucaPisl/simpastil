import rateLimit from '@fastify/rate-limit';
import { sql as drizzleSql } from 'drizzle-orm';
import { AdminService, AdminError } from './admin.service.js';
import { AuditService } from './audit.service.js';
import { AdminTotpService, TotpError } from '../auth/totp.service.js';
import {
  AdminSetupSchema, AdminLoginSchema, AdminRefreshSchema,
  CreateKeySchema, InviteSchema, ChangePasswordSchema, AdminAuditLogsQuerySchema,
} from './admin.schema.js';
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

function sendTotpError(reply: FastifyReply, err: unknown): FastifyReply {
  if (err instanceof TotpError) return reply.status(err.statusCode).send({ error: err.message, code: err.code });
  throw err;
}

export default async function adminRoutes(fastify: FastifyInstance, opts: { db: Db; config: AppConfig & { role: 'api' | 'test' }; crypto: EncryptionCapabilities; payloadSealer: DeliveryPayloadSealer; rateLimitMax?: number; rateLimitTimeWindow?: string | number; ttlSeconds?: number; sessionService?: SessionService }) {
  const database = opts.db;
  const sessions = opts.sessionService ?? new SessionService(database, { environmentManagedAdmin: opts.config.admin !== undefined });
  const ttlSeconds = opts.ttlSeconds ?? opts.config.jwt.accessTokenTtlSeconds;

  const service = new AdminService(
    database,
    (sessionVersion = '1') => fastify.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion }, { expiresIn: ttlSeconds }),
    (sessionVersion = '1') => fastify.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion, purpose: '2fa-challenge' }, { expiresIn: 300 }),
    opts.crypto,
    opts.config.admin ? { credentials: opts.config.admin } : {},
    sessions,
  );
  const audit = new AuditService(database);
  const adminTotp = new AdminTotpService(database, opts.crypto, sessions);
  const recovery = new RecoveryService(database, opts.payloadSealer, opts.crypto, opts.config.publicAppUrl, sessions);

  function clientIp(req: FastifyRequest): string | null {
    return req.ip ?? null;
  }

  // adminGuard — registered in this scope, used only by routes in this plugin
  fastify.decorate('adminGuard', async (req: FastifyRequest, reply: FastifyReply) => {
    try {
      await req.jwtVerify();
      const payload = req.user as unknown as {
        sub: string;
        role?: unknown;
        exp?: unknown;
        sessionVersion?: unknown;
        purpose?: unknown;
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
        return reply.status(401).send({ error: 'Unauthorized', code: ErrorCode.ADMIN_UNAUTHORIZED });
      }
    } catch {
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
      } catch (err) { return sendAdminError(reply, err); }
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

  fastify.post('/admin/auth/logout-all', { preHandler: [fastify.adminGuard] }, async (_request, reply) => {
    try {
      await service.logoutAll();
      return reply.status(204).send();
    } catch (err) { return sendAdminError(reply, err); }
  });

  // ── Admin 2FA ──────────────────────────────────────────────────────────────

  fastify.post('/admin/auth/2fa/setup', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    try {
      const result = await adminTotp.setup();
      return reply.status(200).send(result);
    } catch (err) { return sendTotpError(reply, err); }
  });

  fastify.post('/admin/auth/2fa/enable', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { code } = (request.body as { code?: string }) ?? {};
    if (!code) return reply.status(400).send({ error: 'code is required', code: ErrorCode.VALIDATION_ERROR });
    try {
      const result = await adminTotp.enable(code);
      await audit.log('admin', 'admin.2fa_enable', 'admin', null, clientIp(request));
      return reply.status(200).send(result);
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
      return reply.status(200).send(result);
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
        if (err instanceof TotpError) return sendTotpError(reply, err);
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

  // ── Audit logs ──────────────────────────────────────────────────────────────
  fastify.get('/admin/audit-logs', { preHandler: [fastify.adminGuard] }, async (request, reply) => {
    const { limit, offset, action } = AdminAuditLogsQuerySchema.parse(request.query);
    const entries = await audit.list({
      limit: limit ?? 50,
      offset: offset ?? 0,
      action,
    });
    return reply.status(200).send({ logs: entries });
  });
}
