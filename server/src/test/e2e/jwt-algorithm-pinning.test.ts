import { createHmac, createSign } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import type { Db } from '../../db/client.js';

const EMAIL = 'alg-pin@example.com';
const PASSWORD = 'password1234';
const ADMIN_PASSWORD = 'adminpassword1234';

function b64url(value: string | Buffer): string {
  return Buffer.from(value).toString('base64url');
}

function claims(subject: string, extra: Record<string, unknown> = {}): string {
  const now = Math.floor(Date.now() / 1000);
  return b64url(JSON.stringify({ sub: subject, sessionVersion: '1', iat: now, exp: now + 300, ...extra }));
}

/** HS256 token whose HMAC secret is the (public) verification key. */
function hs256TokenSignedWithPublicKey(publicKey: string, payload: string): string {
  const signingInput = `${b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))}.${payload}`;
  return `${signingInput}.${createHmac('sha256', publicKey).update(signingInput).digest('base64url')}`;
}

/** Unsigned token with `alg: none` and an empty signature. */
function noneToken(payload: string): string {
  return `${b64url(JSON.stringify({ alg: 'none', typ: 'JWT' }))}.${payload}.`;
}

/** Genuine signature from the real private key, but with the RS384 algorithm. */
function rs384TokenSignedWithPrivateKey(privateKey: string, payload: string): string {
  const signingInput = `${b64url(JSON.stringify({ alg: 'RS384', typ: 'JWT' }))}.${payload}`;
  const signature = createSign('RSA-SHA384').update(signingInput).sign(privateKey);
  return `${signingInput}.${b64url(signature)}`;
}

describe('JWT verification pins the RS256 algorithm', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;
  let apiKey: string;
  const privateKey = process.env['JWT_PRIVATE_KEY']!;
  const publicKey = process.env['JWT_PUBLIC_KEY']!;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({ db: appDb, privateKey, publicKey, ttlSeconds: 60 });
    apiKey = await createUnclaimedKey(superDb);
  });

  afterAll(async () => { await app.close(); await cleanup(); });
  afterEach(async () => {
    await truncateAll(superDb);
    apiKey = await createUnclaimedKey(superDb);
  });

  async function registerUser(): Promise<string> {
    const registration = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    return registration.json<{ userId: string }>().userId;
  }

  async function setupAdmin(): Promise<void> {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST',
      url: '/api/v1/admin/setup',
      payload: { email: 'alg-pin-admin@test.com', password: ADMIN_PASSWORD, proof },
    });
  }

  const forgeries: ReadonlyArray<[string, (subject: string, extra?: Record<string, unknown>) => string]> = [
    ['HS256 signed with the public key as HMAC secret', (sub, extra) => hs256TokenSignedWithPublicKey(publicKey, claims(sub, extra))],
    ['alg none with an empty signature', (sub, extra) => noneToken(claims(sub, extra))],
    ['RS384 signed with the real private key', (sub, extra) => rs384TokenSignedWithPrivateKey(privateKey, claims(sub, extra))],
  ];

  it('accepts a genuine RS256 user token (positive control)', async () => {
    const userId = await registerUser();
    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${app.jwt.sign({ sub: userId, sessionVersion: '1' })}`, 'X-Api-Key': apiKey },
    });
    expect(res.statusCode).toBe(200);
  });

  it.each(forgeries)('rejects %s at the user gate', async (_label, forge) => {
    const userId = await registerUser();
    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${forge(userId)}`, 'X-Api-Key': apiKey },
    });
    expect(res.statusCode).toBe(401);
  });

  it.each(forgeries)('rejects %s at the admin gate', async (_label, forge) => {
    await setupAdmin();
    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/users',
      headers: { Authorization: `Bearer ${forge('admin', { role: 'admin' })}` },
    });
    expect(res.statusCode).toBe(401);
  });

  it.each(forgeries)('rejects %s in direct verification (challenge-token path)', async (_label, forge) => {
    const userId = await registerUser();
    expect(() => app.jwt.verify(forge(userId))).toThrow();
    expect(app.jwt.verify<{ sub: string }>(app.jwt.sign({ sub: userId, sessionVersion: '1' })).sub).toBe(userId);
  });

  it.each(forgeries)('rejects %s as a 2FA challenge token', async (_label, forge) => {
    const userId = await registerUser();
    // Only the algorithm is wrong: every other claim matches a real challenge token.
    const token = forge(userId, { purpose: '2fa-challenge' });
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/2fa/challenge',
      headers: { 'X-Api-Key': apiKey },
      payload: { challengeToken: token, code: '000000' },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json<{ code: string }>().code).toBe('TOTP_CHALLENGE_INVALID');
  });
});
