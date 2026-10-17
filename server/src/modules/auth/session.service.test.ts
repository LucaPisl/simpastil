import { describe, expect, it } from 'vitest';
import type { Db } from '../../db/client.js';
import { AdminError, AdminService } from '../admin/admin.service.js';
import { ErrorCode } from '../shared/errors.js';
import { SessionService } from './session.service.js';

function fakeDb(transaction: (work: (tx: unknown) => Promise<unknown>) => Promise<unknown>): Db {
  return {
    transaction,
    select: () => ({ from: async () => [] }),
  } as unknown as Db;
}

describe('SessionService environment-admin serialization', () => {
  it('serializes issuance and invalidation work and publishes only after commit', async () => {
    let active = 0;
    let maximumActive = 0;
    let secondStarted = false;
    let releaseFirst!: () => void;
    let firstEntered!: () => void;
    const firstGate = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const entered = new Promise<void>((resolve) => { firstEntered = resolve; });
    const db = fakeDb(async (work) => work({}));
    const sessions = new SessionService(db, { environmentManagedAdmin: true });

    const first = sessions.runAdminSessionTransaction(async () => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      firstEntered();
      await firstGate;
      active -= 1;
      return 'first';
    });
    await entered;

    const second = sessions.runAdminSessionTransaction(async () => {
      secondStarted = true;
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      active -= 1;
      return 'second';
    });
    await Promise.resolve();
    expect(secondStarted).toBe(false);
    releaseFirst();
    await expect(Promise.all([first, second])).resolves.toEqual(['first', 'second']);
    expect(maximumActive).toBe(1);

    let committed = false;
    let publishedBeforeCommit = false;
    const commitDb = fakeDb(async (work) => {
      const result = await work({});
      committed = true;
      return result;
    });
    const commitSessions = new SessionService(commitDb, { environmentManagedAdmin: true });
    await commitSessions.runAdminSessionTransaction(
      async () => 'published-generation',
      (generation) => {
        publishedBeforeCommit = !committed;
        expect(generation).toBe('published-generation');
        return '123';
      },
    );
    expect(publishedBeforeCommit).toBe(false);
  });

  it('does not issue the next generation until the previous commit is acknowledged', async () => {
    let releaseCommit!: () => void;
    let workCompleted!: () => void;
    let commitReturned = false;
    let secondIssuanceStarted = false;
    const commitGate = new Promise<void>((resolve) => { releaseCommit = resolve; });
    const issuanceCompleted = new Promise<void>((resolve) => { workCompleted = resolve; });
    const db = fakeDb(async (work) => {
      const result = await work({});
      workCompleted();
      await commitGate;
      commitReturned = true;
      return result;
    });
    const sessions = new SessionService(db, { environmentManagedAdmin: true });

    const firstIssuance = sessions.runAdminSessionTransaction(
      async () => {
        const issued = { accessToken: 'access-1', refreshToken: 'refresh-1', sessionVersion: '2' };
        return issued;
      },
      (issued) => {
        expect(commitReturned).toBe(true);
        return issued.sessionVersion;
      },
    );
    await issuanceCompleted;

    const secondIssuance = sessions.runAdminSessionTransaction(async () => {
      secondIssuanceStarted = true;
      return 'second-issuance';
    });
    await Promise.resolve();
    expect(secondIssuanceStarted).toBe(false);

    releaseCommit();
    await expect(firstIssuance).resolves.toMatchObject({ sessionVersion: '2' });
    await expect(secondIssuance).resolves.toBe('second-issuance');
    expect(secondIssuanceStarted).toBe(true);
  });

  it('rejects stale AdminService issuance after delayed invalidation commit acknowledgement', async () => {
    const insertedRows: unknown[] = [];
    let transactionNumber = 0;
    let releaseCommit!: () => void;
    let invalidationWorkCompleted!: () => void;
    const commitGate = new Promise<void>((resolve) => { releaseCommit = resolve; });
    const invalidationEntered = new Promise<void>((resolve) => { invalidationWorkCompleted = resolve; });
    const db = fakeDb(async (work) => {
      transactionNumber += 1;
      let executeCount = 0;
      const updateBuilder = {
        set: (_values: unknown) => updateBuilder,
        where: async (_condition: unknown) => [],
        returning: async (_fields: unknown) => [],
      };
      const tx = {
        execute: async () => {
          executeCount += 1;
          return executeCount >= 3 ? [{ now: new Date() }] : [];
        },
        update: (_table: unknown) => updateBuilder,
        insert: (_table: unknown) => ({
          values: async (values: unknown) => { insertedRows.push(values); },
        }),
      };
      const result = await work(tx);
      if (transactionNumber === 1) {
        invalidationWorkCompleted();
        await commitGate;
      }
      return result;
    });
    const sessions = new SessionService(db, { environmentManagedAdmin: true });
    const service = new AdminService(
      db,
      (version = '1') => `access-${version}`,
      (version = '1') => `challenge-${version}`,
      { encrypt: (value: string) => value, decrypt: (value: string) => value, isEncrypted: () => false },
      { credentials: { email: 'admin@example.invalid', password: 'password1234' } },
      sessions,
    );

    const staleVersion = await sessions.getAdminSessionVersion();
    expect(staleVersion).toBeTruthy();
    const invalidation = sessions.invalidateAdminSessions();
    await invalidationEntered;

    const staleIssuance = service.issueTokens(staleVersion!);
    await Promise.resolve();
    expect(insertedRows).toHaveLength(0);

    releaseCommit();
    await invalidation;
    await expect(staleIssuance).rejects.toMatchObject<Partial<AdminError>>({
      code: ErrorCode.AUTH_SESSION_REVOKED,
    });
    expect(insertedRows).toHaveLength(0);
    await expect(sessions.assertAdminSession(staleVersion)).resolves.toBe(false);
  });
});
