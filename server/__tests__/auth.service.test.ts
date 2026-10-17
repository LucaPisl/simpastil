/**
 * AuthService integration tests.
 *
 * These tests use a real PostgreSQL test database (DATABASE_URL_APP).
 * Run `npm run db:setup-test` once before running these tests.
 */

import {
  afterAll,
  beforeAll,
  describe,
  expect,
  it,
} from 'vitest';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import postgres from 'postgres';
import { drizzle } from 'drizzle-orm/postgres-js';
import * as schema from '../src/db/schema.js';
import { AuthService, AuthError } from '../src/modules/auth/auth.service.js';
import type { Db } from '../src/db/client.js';

// ---------------------------------------------------------------------------
// Test database setup
// ---------------------------------------------------------------------------

const APP_URL = process.env['DATABASE_URL_APP'];
if (!APP_URL) throw new Error('DATABASE_URL_APP must be set to run auth tests');

const SUPER_URL = process.env['DATABASE_URL_SUPER'];
if (!SUPER_URL) throw new Error('DATABASE_URL_SUPER must be set to run auth tests');

// pgClient: superuser connection used for raw-SQL verification queries in tests.
// Using the superuser bypasses RLS so verification queries can read any row
// regardless of app.current_user_id — appropriate for test assertions only.
const pgClient = postgres(SUPER_URL, { max: 3 });

// appPgClient: app_user connection used by AuthService (RLS enforced).
const appPgClient = postgres(APP_URL, { max: 3 });
const db = drizzle(appPgClient, { schema }) as Db;

// Dummy JWT signer for tests — returns a predictable string, not a real JWT.
// Tests that need to verify JWT fields (alg, exp) do so in the routes tests.
const fakeSign = (userId: string) => `test-token.${userId}`;

let service: AuthService;

beforeAll(() => {
  service = new AuthService(db, fakeSign);
});

afterAll(async () => {
  // Best-effort cleanup of any test users created during this run.
  // Uses a prefix that only test code generates.
  await pgClient`DELETE FROM users WHERE email LIKE 'authtest-%@example.com'`;
  // Clean up unclaimed test keys not removed by CASCADE (userId IS NULL).
  await pgClient`DELETE FROM api_keys WHERE user_id IS NULL AND label = 'test'`;
  await pgClient.end();
  await appPgClient.end();
});

// Generates a unique test email to prevent cross-test conflicts.
const testEmail = () =>
  `authtest-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`;

/** Inserts an unclaimed API key via superuser and returns its UUID. */
async function insertUnclaimedKey(): Promise<string> {
  const { createHash, randomBytes } = await import('node:crypto');
  const rawKey = randomBytes(32).toString('hex');
  const keyHash = createHash('sha256').update(rawKey).digest('hex');
  const keyId = randomUUID();
  await pgClient`INSERT INTO api_keys (id, key_hash, label) VALUES (${keyId}, ${keyHash}, 'test')`;
  return keyId;
}

// ---------------------------------------------------------------------------
// register()
// ---------------------------------------------------------------------------

describe('register()', () => {
  it('returns a userId on success', async () => {
    const result = await service.register(testEmail(), 'validpassword123', await insertUnclaimedKey());
    expect(result.userId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
  });

  it('normalises email to lowercase and trimmed before storing', async () => {
    const email = testEmail();
    const mixedCase = `  ${email.toUpperCase()}  `;
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(mixedCase, 'validpassword123', keyId);

    // Verify the normalized form is in the DB (login with normalized form succeeds)
    const result = await service.login(email, 'validpassword123', { keyId, keyUserId: userId });
    expect(result.accessToken).toBeTruthy();
  });

  it('throws 409 on duplicate email (case-insensitive)', async () => {
    const email = testEmail();
    await service.register(email, 'firstpassword123', await insertUnclaimedKey());
    await expect(service.register(email.toUpperCase(), 'secondpassword123', await insertUnclaimedKey()))
      .rejects.toMatchObject({ statusCode: 409 });
  });

  it('never stores the raw password in the database', async () => {
    const email = testEmail();
    const password = 'supersecretpassword';
    await service.register(email, password, await insertUnclaimedKey());

    const [user] = await pgClient`SELECT password_hash FROM users WHERE email = ${email}`;
    expect(user?.password_hash).not.toBe(password);
    expect(user?.password_hash).toMatch(/^\$argon2id\$/);
  });

  it('rejects passwords shorter than 10 characters', async () => {
    await expect(service.register(testEmail(), 'short', await insertUnclaimedKey()))
      .rejects.toMatchObject({ statusCode: 400 });
  });

  it('rejects passwords longer than 72 characters', async () => {
    await expect(service.register(testEmail(), 'a'.repeat(73), randomUUID()))
      .rejects.toMatchObject({ statusCode: 400 });
  });
});

// ---------------------------------------------------------------------------
// login()
// ---------------------------------------------------------------------------

describe('login()', () => {
  it('returns accessToken and refreshToken on valid credentials', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);

    const result = await service.login(email, 'validpassword123', { keyId, keyUserId: userId });
    expect(result.accessToken).toMatch(/^test-token\./);
    expect(result.refreshToken).toMatch(/^[0-9a-f]{64}$/); // 256-bit hex
  });

  it('normalises email before lookup (accepts mixed-case login)', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);

    // Login with uppercase should succeed — stored as lowercase
    const result = await service.login(email.toUpperCase(), 'validpassword123', { keyId, keyUserId: userId });
    expect(result.accessToken).toBeTruthy();
  });

  it('throws 401 on wrong password', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);

    await expect(service.login(email, 'wrongpassword', { keyId, keyUserId: userId }))
      .rejects.toMatchObject({ statusCode: 401 });
  });

  it('throws 401 on unknown email (same error shape — no enumeration)', async () => {
    const keyId = await insertUnclaimedKey();
    await expect(service.login('nobody@example.com', 'validpassword123', { keyId, keyUserId: null }))
      .rejects.toMatchObject({ statusCode: 401 });
  });

  it('stores only the SHA-256 hash of the refresh token, not the raw value', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);
    const { refreshToken } = await service.login(email, 'validpassword123', { keyId, keyUserId: userId });

    const rows = await pgClient`
      SELECT token_hash FROM refresh_tokens
      WHERE token_hash = encode(digest(${refreshToken}, 'sha256'), 'hex')
    `;
    expect(rows.length).toBe(1);

    // The raw token must not appear in the DB
    const rawRows = await pgClient`
      SELECT token_hash FROM refresh_tokens WHERE token_hash = ${refreshToken}
    `;
    expect(rawRows.length).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// refresh()
// ---------------------------------------------------------------------------

describe('refresh()', () => {
  it('returns a new token pair and revokes the old refresh token', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);
    const { refreshToken: original } = await service.login(email, 'validpassword123', { keyId, keyUserId: userId });

    const result = await service.refresh(original);
    expect(result.accessToken).toBeTruthy();
    expect(result.refreshToken).toMatch(/^[0-9a-f]{64}$/);
    expect(result.refreshToken).not.toBe(original);

    // Old token must now be revoked
    const [oldRow] = await pgClient`
      SELECT revoked FROM refresh_tokens
      WHERE token_hash = encode(digest(${original}, 'sha256'), 'hex')
    `;
    expect(oldRow?.revoked).toBe(true);
  });

  it('new token belongs to the same family as the old token', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);
    const { refreshToken: t1 } = await service.login(email, 'validpassword123', { keyId, keyUserId: userId });
    const { refreshToken: t2 } = await service.refresh(t1);

    const [row1] = await pgClient`
      SELECT family_id FROM refresh_tokens
      WHERE token_hash = encode(digest(${t1}, 'sha256'), 'hex')
    `;
    const [row2] = await pgClient`
      SELECT family_id FROM refresh_tokens
      WHERE token_hash = encode(digest(${t2}, 'sha256'), 'hex')
    `;
    expect(row1?.family_id).toBe(row2?.family_id);
  });

  it('throws 401 for an unknown token', async () => {
    const fakeToken = randomBytes(32).toString('hex');
    await expect(service.refresh(fakeToken))
      .rejects.toMatchObject({ statusCode: 401 });
  });

  it('throws 401 for an expired token', async () => {
    const email = testEmail();
    const { userId } = await service.register(email, 'validpassword123', await insertUnclaimedKey());

    // Insert an already-expired token directly
    const rawToken = randomBytes(32).toString('hex');
    const tokenHash = createHash('sha256').update(rawToken).digest('hex');
    await pgClient`
      INSERT INTO refresh_tokens (user_id, token_hash, family_id, expires_at, revoked)
      VALUES (
        ${userId}::uuid,
        ${tokenHash},
        ${randomUUID()}::uuid,
        NOW() - INTERVAL '1 second',
        false
      )
    `;

    await expect(service.refresh(rawToken))
      .rejects.toMatchObject({ statusCode: 401 });
  });

  it('REUSE DETECTION: replaying a revoked token revokes the entire family and returns 401', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);
    const { refreshToken: t1 } = await service.login(email, 'validpassword123', { keyId, keyUserId: userId });

    // Legitimate rotation: t1 -> t2
    const { refreshToken: t2 } = await service.refresh(t1);

    // t1 is now revoked. Replaying it should trigger family invalidation.
    await expect(service.refresh(t1))
      .rejects.toMatchObject({ statusCode: 401 });

    // t2 (the newer token in the same family) must also now be revoked
    const [row2] = await pgClient`
      SELECT revoked FROM refresh_tokens
      WHERE token_hash = encode(digest(${t2}, 'sha256'), 'hex')
    `;
    expect(row2?.revoked).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// logout()
// ---------------------------------------------------------------------------

describe('logout()', () => {
  it('marks the token as revoked', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);
    const { refreshToken } = await service.login(email, 'validpassword123', { keyId, keyUserId: userId });

    await service.logout(refreshToken);

    const [row] = await pgClient`
      SELECT revoked FROM refresh_tokens
      WHERE token_hash = encode(digest(${refreshToken}, 'sha256'), 'hex')
    `;
    expect(row?.revoked).toBe(true);
  });

  it('a revoked token cannot be used to refresh', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);
    const { refreshToken } = await service.login(email, 'validpassword123', { keyId, keyUserId: userId });

    await service.logout(refreshToken);

    await expect(service.refresh(refreshToken))
      .rejects.toMatchObject({ statusCode: 401 });
  });

  it('is idempotent — does not throw for an unknown token', async () => {
    const unknownToken = randomBytes(32).toString('hex');
    await expect(service.logout(unknownToken)).resolves.toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// Security invariants
// ---------------------------------------------------------------------------

describe('Security invariants', () => {
  it('token hash stored in DB is SHA-256 of the raw token (not the raw token)', async () => {
    const email = testEmail();
    const keyId = await insertUnclaimedKey();
    const { userId } = await service.register(email, 'validpassword123', keyId);
    const { refreshToken } = await service.login(email, 'validpassword123', { keyId, keyUserId: userId });

    const expectedHash = createHash('sha256').update(refreshToken).digest('hex');

    const [row] = await pgClient`
      SELECT token_hash FROM refresh_tokens WHERE token_hash = ${expectedHash}
    `;
    expect(row?.token_hash).toBe(expectedHash);
    expect(row?.token_hash).not.toBe(refreshToken);
  });

  it('AuthError carries a statusCode (routes can send correct HTTP status)', () => {
    const err = new AuthError('test', 401);
    expect(err.statusCode).toBe(401);
    expect(err).toBeInstanceOf(Error);
  });
});
