import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { TOTP, Secret } from 'otpauth';
import { eq } from 'drizzle-orm';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs, prepareBootstrapProof, truncateAll, createUnclaimedKey } from '../helpers/db-helpers.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';
import { adminConfig, users } from '../../db/schema.js';

const EMAIL = 'purpose-test@example.com';
const PASSWORD = 'password1234';
const ADMIN_PASSWORD = 'adminpassword1234';

describe('2FA challenge token must be rejected at data gates', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;
  let apiKey: string;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 60,
    });
    apiKey = await createUnclaimedKey(superDb);
  });

  afterAll(async () => { await app.close(); await cleanup(); });
  afterEach(async () => {
    await truncateAll(superDb);
    apiKey = await createUnclaimedKey(superDb);
  });

  async function registerAndEnable2fa() {
    await app.inject({
      method: 'POST', url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });

    const loginRes = await app.inject({
      method: 'POST', url: '/api/v1/auth/login',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    const { accessToken } = loginRes.json();

    const setupRes = await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/setup',
      headers: { Authorization: `Bearer ${accessToken}`, 'X-Api-Key': apiKey },
    });
    const { secret } = setupRes.json();
    const totp = new TOTP({ issuer: 'Simpastil', label: EMAIL, secret: Secret.fromBase32(secret), digits: 6, period: 30 });

    await app.inject({
      method: 'POST', url: '/api/v1/auth/2fa/enable',
      headers: { Authorization: `Bearer ${accessToken}`, 'X-Api-Key': apiKey },
      payload: { code: totp.generate() },
    });

    // Now login again to get a challenge token
    const login2 = await app.inject({
      method: 'POST', url: '/api/v1/auth/login',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    return login2.json().challengeToken as string;
  }

  it('rejects user challenge token at authenticated user route (profiles)', async () => {
    const challengeToken = await registerAndEnable2fa();

    const res = await app.inject({
      method: 'GET', url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${challengeToken}`, 'X-Api-Key': apiKey },
    });

    expect(res.statusCode).toBe(401);
  });

  it('rejects admin challenge token at admin route', async () => {
    // Setup admin
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST', url: '/api/v1/admin/setup',
      payload: { email: 'admin@test.com', password: ADMIN_PASSWORD, proof },
    });

    // Login to get admin access token, setup 2FA
    const loginRes = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/login',
      payload: { password: ADMIN_PASSWORD },
    });
    const { accessToken } = loginRes.json();

    const setupRes = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/setup',
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    const { secret } = setupRes.json();
    const totp = new TOTP({ issuer: 'Simpastil', label: 'admin@test.com', secret: Secret.fromBase32(secret), digits: 6, period: 30 });

    await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/2fa/enable',
      headers: { Authorization: `Bearer ${accessToken}` },
      payload: { code: totp.generate() },
    });

    // Login again — get challenge token
    const login2 = await app.inject({
      method: 'POST', url: '/api/v1/admin/auth/login',
      payload: { password: ADMIN_PASSWORD },
    });
    const challengeToken = login2.json().challengeToken as string;

    // Try to use it on admin routes
    const res = await app.inject({
      method: 'GET', url: '/api/v1/admin/users',
      headers: { Authorization: `Bearer ${challengeToken}` },
    });

    expect(res.statusCode).toBe(401);
  });

  it.each([null, '', 'unknown-purpose'])('rejects admin tokens with own purpose=%j', async (purpose) => {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST',
      url: '/api/v1/admin/setup',
      payload: { email: 'admin-purpose@test.com', password: ADMIN_PASSWORD, proof },
    });
    const token = app.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion: '1', purpose });

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/users',
      headers: { Authorization: `Bearer ${token}` },
    });

    expect(res.statusCode).toBe(401);
  });

  it('accepts an otherwise-valid admin token when purpose is absent', async () => {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST',
      url: '/api/v1/admin/setup',
      payload: { email: 'admin-purpose@test.com', password: ADMIN_PASSWORD, proof },
    });
    const token = app.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion: '1' });

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/users',
      headers: { Authorization: `Bearer ${token}` },
    });

    expect(res.statusCode).toBe(200);
  });

  it('rejects an expired admin token', async () => {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST',
      url: '/api/v1/admin/setup',
      payload: { email: 'admin-no-exp@test.com', password: ADMIN_PASSWORD, proof },
    });
    const token = app.jwt.sign(
      { sub: 'admin', role: 'admin', sessionVersion: '1' },
      // Well past the verifier's clock tolerance. `expiresIn: 0` made exp equal iat, which
      // is still valid until the clock second rolls over and made this test flaky.
      { expiresIn: -3600 },
    );

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/users',
      headers: { Authorization: `Bearer ${token}` },
    });

    expect(res.statusCode).toBe(401);
  });

  it('requires the exact admin challenge role', async () => {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST',
      url: '/api/v1/admin/setup',
      payload: { email: 'admin-role@test.com', password: ADMIN_PASSWORD, proof },
    });
    const access = (await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/login',
      payload: { password: ADMIN_PASSWORD },
    })).json<{ accessToken: string }>();
    const setup = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/setup',
      headers: { Authorization: `Bearer ${access.accessToken}` },
    });
    const secret = setup.json<{ secret: string }>().secret;
    const totp = new TOTP({
      issuer: 'Simpastil',
      label: 'admin-role@test.com',
      secret: Secret.fromBase32(secret),
      digits: 6,
      period: 30,
    });
    const enabled = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/enable',
      headers: { Authorization: `Bearer ${access.accessToken}` },
      payload: { code: totp.generate() },
    });
    expect(enabled.statusCode).toBe(200);
    const validChallenge = (await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/login',
      payload: { password: ADMIN_PASSWORD },
    })).json<{ challengeToken: string }>();
    const validClaims = JSON.parse(Buffer.from(validChallenge.challengeToken.split('.')[1]!, 'base64url').toString()) as { sessionVersion: string };
    const token = app.jwt.sign({
      sub: 'admin',
      role: 'not-admin',
      purpose: '2fa-challenge',
      sessionVersion: validClaims.sessionVersion,
    });

    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/challenge',
      payload: { challengeToken: token, code: '000000' },
    });

    expect(res.statusCode).toBe(400);
    expect(res.json<{ code: string }>().code).toBe('TOTP_CHALLENGE_INVALID');

    const control = await app.inject({
      method: 'POST',
      url: '/api/v1/admin/auth/2fa/challenge',
      payload: { challengeToken: validChallenge.challengeToken, code: totp.generate() },
    });
    expect(control.statusCode).toBe(200);
  });

  it('compares positive session versions exactly above JavaScript safe integers', async () => {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST',
      url: '/api/v1/admin/setup',
      payload: { email: 'admin-large-version@test.com', password: ADMIN_PASSWORD, proof },
    });
    const largeVersion = '9007199254740993';
    await superDb.update(adminConfig).set({ sessionVersion: BigInt(largeVersion) });
    const token = app.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion: largeVersion });

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/users',
      headers: { Authorization: `Bearer ${token}` },
    });

    expect(res.statusCode).toBe(200);
  });

  it.each([0, 1, '01', '9223372036854775808'])('rejects admin tokens with non-canonical sessionVersion=%j', async (sessionVersion) => {
    const proof = await prepareBootstrapProof(superDb);
    await app.inject({
      method: 'POST',
      url: '/api/v1/admin/setup',
      payload: { email: 'admin-version@test.com', password: ADMIN_PASSWORD, proof },
    });
    const token = app.jwt.sign({ sub: 'admin', role: 'admin', sessionVersion });

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/users',
      headers: { Authorization: `Bearer ${token}` },
    });

    expect(res.statusCode).toBe(401);
  });

  it.each([null, '', 'unknown-purpose'])('rejects user tokens with own purpose=%j', async (purpose) => {
    const registration = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    const userId = registration.json<{ userId: string }>().userId;
    const token = app.jwt.sign({ sub: userId, sessionVersion: '1', purpose });

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${token}`, 'X-Api-Key': apiKey },
    });

    expect(res.statusCode).toBe(401);
  });

  it('accepts an otherwise-valid user token when purpose is absent', async () => {
    const registration = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    const userId = registration.json<{ userId: string }>().userId;
    const token = app.jwt.sign({ sub: userId, sessionVersion: '1' });

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${token}`, 'X-Api-Key': apiKey },
    });

    expect(res.statusCode).toBe(200);
  });

  it('rejects an expired user token', async () => {
    const registration = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    const userId = registration.json<{ userId: string }>().userId;
    const token = app.jwt.sign(
      { sub: userId, sessionVersion: '1' },
      // Well past the verifier's clock tolerance. `expiresIn: 0` made exp equal iat, which
      // is still valid until the clock second rolls over and made this test flaky.
      { expiresIn: -3600 },
    );

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${token}`, 'X-Api-Key': apiKey },
    });

    expect(res.statusCode).toBe(401);
  });

  it('compares user session versions exactly above JavaScript safe integers', async () => {
    const registration = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    const userId = registration.json<{ userId: string }>().userId;
    const largeVersion = '9007199254740993';
    await superDb.update(users).set({ sessionVersion: BigInt(largeVersion) }).where(eq(users.id, userId));
    const token = app.jwt.sign({ sub: userId, sessionVersion: largeVersion });

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${token}`, 'X-Api-Key': apiKey },
    });

    expect(res.statusCode).toBe(200);
  });

  it.each([0, 1, '01', '9223372036854775808'])('rejects user tokens with non-canonical sessionVersion=%j', async (sessionVersion) => {
    const registration = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      headers: { 'X-Api-Key': apiKey },
      payload: { email: EMAIL, password: PASSWORD },
    });
    const userId = registration.json<{ userId: string }>().userId;
    const token = app.jwt.sign({ sub: userId, sessionVersion });

    const res = await app.inject({
      method: 'GET',
      url: '/api/v1/profiles',
      headers: { Authorization: `Bearer ${token}`, 'X-Api-Key': apiKey },
    });

    expect(res.statusCode).toBe(401);
  });
});
