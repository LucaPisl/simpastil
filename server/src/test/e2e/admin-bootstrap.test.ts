import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { eq, sql as drizzleSql } from 'drizzle-orm';
import { buildApp } from '../helpers/app-factory.js';
import {
  createDbs,
  prepareBootstrapProof,
  truncateAll,
} from '../helpers/db-helpers.js';
import { rotateBootstrapProof, type BootstrapRotationTransaction } from '../../modules/admin/bootstrap-rotation.js';
import { BootstrapService } from '../../modules/admin/bootstrap.service.js';
import { adminBootstrapState, adminConfig } from '../../db/schema.js';
import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';

const ADMIN_EMAIL = 'bootstrap-admin@example.invalid';
const ADMIN_PASSWORD = 'adminpassword1234';

describe('operator-gated administrator bootstrap', () => {
  let app: FastifyInstance;
  let superDb: Db;
  let appDb: Db;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    ({ superDb, appDb, cleanup } = createDbs());
    app = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      ttlSeconds: 900,
    });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  afterEach(async () => {
    await truncateAll(superDb);
  });

  async function setup(proof?: string, email = ADMIN_EMAIL) {
    return app.inject({
      method: 'POST',
      url: '/api/v1/admin/setup',
      payload: {
        email,
        password: ADMIN_PASSWORD,
        ...(proof === undefined ? {} : { proof }),
      },
    });
  }

  it('rejects setup without a bootstrap proof and leaves no admin row', async () => {
    await prepareBootstrapProof(superDb);

    const response = await setup();

    expect(response.statusCode).toBeGreaterThanOrEqual(401);
    expect(response.statusCode).toBeLessThanOrEqual(403);
    expect(await superDb.select({ id: adminConfig.id }).from(adminConfig)).toHaveLength(0);
  });

  it('rejects a wrong or expired proof without consuming the valid generation', async () => {
    await prepareBootstrapProof(superDb);
    const wrong = await setup('f'.repeat(64));
    expect(wrong.statusCode).toBeGreaterThanOrEqual(401);
    expect(wrong.statusCode).toBeLessThanOrEqual(403);

    await truncateAll(superDb);
    const expiredProof = await prepareBootstrapProof(superDb, { expiresAt: new Date(Date.now() - 1_000) });
    const expired = await setup(expiredProof);
    expect(expired.statusCode).toBeGreaterThanOrEqual(401);
    expect(expired.statusCode).toBeLessThanOrEqual(403);

    const [state] = await superDb
      .select({ consumedAt: adminBootstrapState.consumedAt })
      .from(adminBootstrapState);
    expect(state?.consumedAt).toBeNull();
  });

  it('rejects a superseded proof after operator rotation', async () => {
    const superseded = await prepareBootstrapProof(superDb);
    const current = await prepareBootstrapProof(superDb);

    const response = await setup(superseded);

    expect(response.statusCode).toBe(403);
    expect((await response.json()).code).toBe('ADMIN_BOOTSTRAP_INVALID');
    expect((await setup(current)).statusCode).toBe(201);
  });

  it('rolls back admin creation and proof consumption together', async () => {
    const proof = await prepareBootstrapProof(superDb);
    const service = new BootstrapService(appDb);

    await expect(appDb.transaction(async (tx) => {
      await service.consumeAndCreateAdmin(ADMIN_EMAIL, ADMIN_PASSWORD, proof, tx);
      throw new Error('deliberate outer rollback');
    })).rejects.toThrow('deliberate outer rollback');

    expect(await superDb.select({ id: adminConfig.id }).from(adminConfig)).toHaveLength(0);
    const [state] = await superDb
      .select({ consumedAt: adminBootstrapState.consumedAt })
      .from(adminBootstrapState);
    expect(state?.consumedAt).toBeNull();
  });

  it('atomically consumes a valid proof and rejects replay', async () => {
    const proof = await prepareBootstrapProof(superDb);

    const first = await setup(proof);
    expect(first.statusCode).toBe(201);

    const [state] = await superDb
      .select({ consumedAt: adminBootstrapState.consumedAt })
      .from(adminBootstrapState);
    expect(state?.consumedAt).toBeTruthy();

    const replay = await setup(proof, 'replay@example.invalid');
    expect(replay.statusCode).toBe(409);
    expect(await superDb.select({ id: adminConfig.id }).from(adminConfig)).toHaveLength(1);
  });

  it('rotates the proof through the injected privileged transaction', async () => {
    await prepareBootstrapProof(superDb);
    const rotated = await rotateBootstrapProof(
      async (callback) => superDb.transaction(async (tx) => {
        await tx.execute(drizzleSql`SET LOCAL ROLE deployment_authority_owner`);
        return callback(tx as unknown as BootstrapRotationTransaction);
      }),
      { now: new Date('2030-01-01T00:00:00.000Z'), ttlMs: 60_000, randomBytes: () => Buffer.alloc(32, 0x42) },
    );

    expect(rotated.proof).toBe('42'.repeat(32));
    expect(BigInt(rotated.generation)).toBeGreaterThan(1n);
    expect(rotated.expiresAt.toISOString()).toBe('2030-01-01T00:01:00.000Z');
    expect((await setup(rotated.proof)).statusCode).toBe(201);
  });

  it('allows exactly one winner for two concurrent valid proofs', async () => {
    const proof = await prepareBootstrapProof(superDb);

    const responses = await Promise.all([
      setup(proof, 'first@example.invalid'),
      setup(proof, 'second@example.invalid'),
    ]);

    expect(responses.map((response) => response.statusCode).sort()).toEqual([201, 409]);
    expect(await superDb.select({ id: adminConfig.id }).from(adminConfig)).toHaveLength(1);
    const [state] = await superDb
      .select({ consumedAt: adminBootstrapState.consumedAt })
      .from(adminBootstrapState)
      .where(eq(adminBootstrapState.singletonKey, true));
    expect(state?.consumedAt).toBeTruthy();
  });

  it('rate-limits repeated setup proofs before a valid proof can be tried', async () => {
    const limitedApp = await buildApp({
      db: appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      rateLimitMax: 2,
      rateLimitTimeWindow: 100,
    });
    try {
      const proof = await prepareBootstrapProof(superDb);
      const clockStart = new Date();
      vi.useFakeTimers({ now: clockStart, toFake: ['Date'] });
      const request = (presentedProof: string) => limitedApp.inject({
        method: 'POST',
        url: '/api/v1/admin/setup',
        payload: { email: ADMIN_EMAIL, password: ADMIN_PASSWORD, proof: presentedProof },
      });
      const firstWrong = await request('f'.repeat(64));
      expect(firstWrong.statusCode).toBe(403);
      expect(firstWrong.json<{ code: string }>().code).toBe('ADMIN_BOOTSTRAP_INVALID');

      const secondWrong = await request('e'.repeat(64));
      expect(secondWrong.statusCode).toBe(403);
      expect(secondWrong.json<{ code: string }>().code).toBe('ADMIN_BOOTSTRAP_INVALID');

      const limitedWrong = await request('d'.repeat(64));
      expect(limitedWrong.statusCode).toBe(429);
      const limitedWrongBody = limitedWrong.json<{ code: string; retryAfter: number }>();
      expect(limitedWrongBody.code).toBe('RATE_LIMIT_EXCEEDED');
      expect(limitedWrongBody.retryAfter).toBeGreaterThan(0);

      const limitedValid = await request(proof);
      expect(limitedValid.statusCode).toBe(429);
      const limitedValidBody = limitedValid.json<{ code: string; retryAfter: number }>();
      expect(limitedValidBody.code).toBe('RATE_LIMIT_EXCEEDED');
      expect(limitedValidBody.retryAfter).toBeGreaterThan(0);

      vi.setSystemTime(new Date(clockStart.getTime() + 101));
      const recovered = await request(proof);
      expect(recovered.statusCode).toBe(201);
    } finally {
      vi.useRealTimers();
      await limitedApp.close();
    }
  });
});
