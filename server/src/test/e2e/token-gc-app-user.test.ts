import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { sql as drizzleSql } from 'drizzle-orm';
import { randomUUID } from 'node:crypto';
import { startTokenGc, purgeExpiredTokens } from '../../lib/token-gc.js';
import { createDbs, truncateAll } from '../helpers/db-helpers.js';
import { adminRefreshTokens, refreshTokens } from '../../db/schema.js';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner } from '../../db/tenant-transaction.js';

// The API runs token GC on its least-privilege app_user pool, where the
// RESTRICTIVE refresh_tokens delete policy requires tenant context.
describe('token garbage collection as app_user', () => {
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(() => {
    ({ superDb, appDb, cleanup } = createDbs());
  });

  afterAll(async () => {
    await cleanup();
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await truncateAll(superDb);
  });

  it('purges revoked expired refresh tokens of every tenant and keeps live ones', async () => {
    const longAgo = new Date(Date.now() - 400 * 86400_000);
    const users = [randomUUID(), randomUUID()];
    for (const [index, userId] of users.entries()) {
      await superDb.execute(drizzleSql`INSERT INTO users (id, email, password_hash) VALUES (${userId}, ${`gc-${index}@example.invalid`}, 'fixture-hash')`);
      await superDb.insert(refreshTokens).values([
        { userId, tokenHash: `old-${index}`, familyId: randomUUID(), expiresAt: longAgo, revoked: true, createdAt: longAgo },
        { userId, tokenHash: `live-${index}`, familyId: randomUUID(), expiresAt: new Date(Date.now() + 86400_000), revoked: false },
      ]);
    }
    await superDb.insert(adminRefreshTokens).values({
      tokenHash: 'admin-old', familyId: randomUUID(), expiresAt: longAgo, revoked: true, createdAt: longAgo,
    });

    const errors: unknown[] = [];
    const original = console.error;
    console.error = (...args: unknown[]) => { errors.push(args); };
    try {
      const gc = startTokenGc(appDb);
      expect(await gc.drain(Date.now() + 5000)).toBe(true);
    } finally {
      console.error = original;
    }

    expect(errors).toEqual([]);
    const remaining = await superDb.select().from(refreshTokens);
    expect(remaining.map((row) => row.tokenHash).sort()).toEqual(['live-0', 'live-1']);
    expect(await superDb.select().from(adminRefreshTokens)).toHaveLength(0);
  });

  async function seedExpired(count: number): Promise<string[]> {
    const longAgo = new Date(Date.now() - 400 * 86400_000);
    const ids: string[] = [];
    for (let index = 0; index < count; index += 1) {
      const userId = randomUUID();
      ids.push(userId);
      await superDb.execute(drizzleSql`INSERT INTO users (id, email, password_hash) VALUES (${userId}, ${`gc-many-${index}@example.invalid`}, 'fixture-hash')`);
      await superDb.insert(refreshTokens).values({
        userId, tokenHash: `old-many-${index}`, familyId: randomUUID(), expiresAt: longAgo, revoked: true, createdAt: longAgo,
      });
    }
    return ids;
  }

  it('purges every tenant when there are more owners than one batch', async () => {
    await seedExpired(7);
    await purgeExpiredTokens(appDb, 3);
    expect(await superDb.select().from(refreshTokens)).toHaveLength(0);
  });

  it('continues past a tenant whose purge fails', async () => {
    const ids = await seedExpired(5);
    const bad = ids[2]!;
    const realRun = TenantTransactionRunner.prototype.run;
    vi.spyOn(TenantTransactionRunner.prototype, 'run').mockImplementation(function (this: TenantTransactionRunner, userId, op) {
      if (userId === bad) return Promise.reject(new Error('simulated tenant failure'));
      return realRun.call(this, userId, op);
    } as typeof realRun);
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    await purgeExpiredTokens(appDb, 2);

    const remaining = await superDb.select().from(refreshTokens);
    expect(remaining.map((row) => row.userId)).toEqual([bad]);
    expect(errorSpy).toHaveBeenCalledTimes(1);
  });
});
