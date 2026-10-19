import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { TOTP, Secret } from 'otpauth';
import { asc, eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll } from '../helpers/db-helpers.js';
import { auditLogs } from '../../db/schema.js';
import { AuditService, FailedLoginAudit } from '../../modules/admin/audit.service.js';
import type { Db } from '../../db/client.js';

const ADMIN_PASSWORD = 'adminpassword1234';
// The throttle lives in the app and outlives truncateAll, so each test uses its own addresses.
const WRONG_PASSWORD = 'definitely-not-the-password';

describe('failed admin sign-in audit', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
    app = await buildApp({ db: appDb, ...keys, ttlSeconds: 600, trustedProxyHops: 1 });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });
  afterEach(async () => { await truncateAll(superDb); });

  async function setupAdmin(): Promise<void> {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'admin@test.com', password: ADMIN_PASSWORD, proof },
    });
  }

  const attempt = (password: string, ip: string) => app.inject({
    method: 'POST', url: '/api/v1/admin/auth/login', payload: { password },
    headers: { 'x-forwarded-for': ip },
  });
  const failures = () => appDb.select().from(auditLogs)
    .where(eq(auditLogs.action, 'admin.login_failed')).orderBy(asc(auditLogs.createdAt));

  it('records a wrong password as a time and an address, nothing else', async () => {
    await setupAdmin();
    const res = await attempt(WRONG_PASSWORD, '203.0.113.5');
    expect(res.statusCode).toBe(401);

    const rows = await failures();
    expect(rows).toHaveLength(1);
    const row = rows[0]!;
    expect(row.ipAddress).toBe('203.0.113.5');
    expect(row.createdAt).toBeInstanceOf(Date);
    expect(row.targetId).toBeNull();
    expect(row.metadata).toBeNull();
    const everything = JSON.stringify(row);
    expect(everything).not.toContain(WRONG_PASSWORD);
    expect(everything).not.toContain('admin@test.com');
  });

  it('writes at most one entry per address per minute', async () => {
    await setupAdmin();
    for (let i = 0; i < 4; i += 1) expect((await attempt(WRONG_PASSWORD, '198.18.0.5')).statusCode).toBe(401);
    expect(await failures()).toHaveLength(1);

    await attempt(WRONG_PASSWORD, '198.18.0.6');
    expect((await failures()).map((r) => r.ipAddress).sort()).toEqual(['198.18.0.5', '198.18.0.6']);
  });

  it('uses the trusted-proxy address, not a client-supplied prefix', async () => {
    await setupAdmin();
    await attempt(WRONG_PASSWORD, '198.51.100.99, 198.19.0.5');
    expect((await failures()).map((r) => r.ipAddress)).toEqual(['198.19.0.5']);
  });

  it('does not record a successful sign-in as a failure', async () => {
    await setupAdmin();
    expect((await attempt(ADMIN_PASSWORD, '203.0.113.5')).statusCode).toBe(200);
    expect(await failures()).toHaveLength(0);
  });

  it('records a wrong two-factor code but not a bad challenge token', async () => {
    await setupAdmin();
    const first = await attempt(ADMIN_PASSWORD, '203.0.113.5');
    const token = first.json().accessToken as string;
    const setup = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/setup', headers: { authorization: `Bearer ${token}` },
    });
    const { secret } = setup.json<{ secret: string }>();
    const totp = new TOTP({ issuer: 'Simpastil', label: 'admin@test.com', secret: Secret.fromBase32(secret), digits: 6, period: 30 });
    await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/enable',
      headers: { authorization: `Bearer ${token}` }, payload: { code: totp.generate() },
    });

    const login = await attempt(ADMIN_PASSWORD, '203.0.113.7');
    const { challengeToken } = login.json<{ challengeToken: string }>();

    const forged = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/challenge', headers: { 'x-forwarded-for': '203.0.113.8' },
      payload: { challengeToken: 'not-a-token', code: '000000' },
    });
    expect(forged.statusCode).toBe(400);
    expect(await failures()).toHaveLength(0);

    const wrong = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/challenge', headers: { 'x-forwarded-for': '203.0.113.7' },
      payload: { challengeToken, code: '000000' },
    });
    expect(wrong.statusCode).toBe(400);
    const rows = await failures();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.ipAddress).toBe('203.0.113.7');
    expect(rows[0]!.metadata).toBeNull();
  });

  describe('throttle', () => {
    it('lets an address log again once the window has passed', async () => {
      let now = 1_000_000;
      const written: Array<string | null> = [];
      const audit = { log: async (_a: string, _b: string, _c: string, _d: null, ip: string | null) => { written.push(ip); } } as unknown as AuditService;
      const throttle = new FailedLoginAudit(audit, () => now);

      expect(await throttle.record('1.1.1.1')).toBe(true);
      now += 59_999;
      expect(await throttle.record('1.1.1.1')).toBe(false);
      now += 1;
      expect(await throttle.record('1.1.1.1')).toBe(true);
      expect(written).toEqual(['1.1.1.1', '1.1.1.1']);
    });

    it('treats an unknown address as one address and survives a failing write', async () => {
      let fail = true;
      let writes = 0;
      const audit = { log: async () => { if (fail) throw new Error('db down'); writes += 1; } } as unknown as AuditService;
      const throttle = new FailedLoginAudit(audit, () => 5);

      expect(await throttle.record(null)).toBe(false);
      fail = false;
      // The failed write did not use up the window.
      expect(await throttle.record(null)).toBe(true);
      expect(await throttle.record(null)).toBe(false);
      expect(writes).toBe(1);
    });

    it('stays bounded under a flood of distinct addresses', async () => {
      const audit = { log: async () => undefined } as unknown as AuditService;
      const throttle = new FailedLoginAudit(audit, () => 10);
      for (let i = 0; i < 1500; i += 1) await throttle.record(`10.0.${Math.floor(i / 250)}.${i % 250}`);
      expect((throttle as unknown as { lastLogged: Map<string, number> }).lastLogged.size).toBeLessThanOrEqual(1000);
    });
  });
});
