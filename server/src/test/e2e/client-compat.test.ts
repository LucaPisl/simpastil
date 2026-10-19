import { describe, expect, it, vi } from 'vitest';
import Fastify from 'fastify';
import capabilitiesRoutes from '../../modules/capabilities/capabilities.routes.js';
import clientBuildGatePlugin from '../../plugins/client-build-gate.js';
import type { Db } from '../../db/client.js';
import type { PrivilegedCommandContext } from '../../db/provision.js';
import type { RuntimeEnvironment } from '../../config/app-config.js';
import type { Sql } from 'postgres';
import { readServerVersion } from '../../modules/updates/update-checker.js';
import { setMinimumClientBuild } from '../../db/set-minimum-client-build.js';

function gateApp(minimumClientBuild: number) {
  const transaction = {
    select: () => ({
      from: () => ({
        where: async () => [{ minimumClientBuild }],
      }),
    }),
  };
  const db = { transaction: async (run: (tx: typeof transaction) => unknown) => run(transaction) } as unknown as Db;
  const app = Fastify({ logger: false });
  app.decorateRequest('correlationId', 'test-correlation-id');
  app.register(clientBuildGatePlugin, { db });
  app.register(async (instance) => {
    instance.post('/write', {
      config: { clientBuildGate: true },
      preHandler: [instance.clientBuildGate],
    }, async (request) => ({ clientBuild: request.clientBuild }));
    instance.get('/read', { preHandler: [instance.clientBuildGate] }, async () => ({ read: true }));
  });
  return app;
}

describe('route-marked client build gate', () => {
  it('treats a missing header as build 1 and rejects only the marked mutation', async () => {
    const app = gateApp(2);
    await app.ready();
    const rejected = await app.inject({ method: 'POST', url: '/write' });
    expect(rejected.statusCode).toBe(426);
    expect(rejected.json().error.code).toBe('CLIENT_UPGRADE_REQUIRED');
    const read = await app.inject({ method: 'GET', url: '/read' });
    expect(read.statusCode).toBe(200);
    await app.close();
  });

  it('accepts the enforced build and rejects malformed build headers', async () => {
    const app = gateApp(2);
    await app.ready();
    const accepted = await app.inject({ method: 'POST', url: '/write', headers: { 'X-Simpastil-Client-Build': '2' } });
    expect(accepted.statusCode).toBe(200);
    expect(accepted.json()).toEqual({ clientBuild: 2 });
    const malformed = await app.inject({ method: 'POST', url: '/write', headers: { 'X-Simpastil-Client-Build': '02' } });
    expect(malformed.statusCode).toBe(400);
    expect(malformed.json().error.code).toBe('VALIDATION_ERROR');
    await app.close();
  });

  it('compatibility profile bypasses only the minimum-build rejection', async () => {
    const previousProfile = process.env['SIMPASTIL_BUILD_PROFILE'];
    process.env['SIMPASTIL_BUILD_PROFILE'] = 'compatibility';
    const app = gateApp(2);
    try {
      await app.ready();
      const legacy = await app.inject({ method: 'POST', url: '/write' });
      expect(legacy.statusCode).toBe(200);
      expect(legacy.json()).toEqual({ clientBuild: 1 });

      const malformed = await app.inject({
        method: 'POST',
        url: '/write',
        headers: { 'X-Simpastil-Client-Build': '02' },
      });
      expect(malformed.statusCode).toBe(400);
      expect(malformed.json().error.code).toBe('VALIDATION_ERROR');
    } finally {
      if (previousProfile === undefined) {
        delete process.env['SIMPASTIL_BUILD_PROFILE'];
      } else {
        process.env['SIMPASTIL_BUILD_PROFILE'] = previousProfile;
      }
      await app.close();
    }
  });
});

function commandHarness(enforcedMinimumClientBuild: number, targetMinimumClientBuild: number) {
  const unsafe = vi.fn(async (query: string) => {
    if (query.includes('FROM public.deployment_manifest')) {
      return [{
        contractVersion: '2',
        ledgerActivated: false,
        enforcedMinimumClientBuild,
        targetMinimumClientBuild,
      }];
    }
    return [];
  });
  const transaction = { unsafe };
  const sql = { begin: async (run: (tx: typeof transaction) => unknown) => run(transaction) } as unknown as Sql;
  const context = {
    sql,
    environment: {} as RuntimeEnvironment,
    args: ['2', '--change-ref', 'release-42'],
  } satisfies PrivilegedCommandContext;
  return { context, unsafe };
}

describe('privileged minimum client build command', () => {
  it('updates only the enforced value through the audited authority function', async () => {
    const { context, unsafe } = commandHarness(1, 2);
    await setMinimumClientBuild(context);
    expect(unsafe).toHaveBeenCalledTimes(2);
    expect(unsafe.mock.calls[1]?.[0]).toContain('public.set_deployment_authority');
    expect(unsafe.mock.calls[1]?.[1]).toEqual(['2', false, 2, 'release-42']);
  });

  it('refuses values beyond the immutable artifact target without an authority write', async () => {
    const { context, unsafe } = commandHarness(1, 2);
    context.args = ['3', '--change-ref', 'release-43'];
    await expect(setMinimumClientBuild(context)).rejects.toThrow('cannot exceed the immutable artifact target');
    expect(unsafe).toHaveBeenCalledTimes(1);
  });
});

describe('GET /capabilities', () => {
  it('returns only the public dynamic authority fields', async () => {
    let ledgerActive = false;
    let minimumClientBuild = 1;
    const db = {
      select: () => ({
        from: () => ({
          where: async () => [{ ledgerActivated: ledgerActive, minimumClientBuild, serverRelease: 'release-42' }],
        }),
      }),
    } as unknown as Db;
    const app = Fastify({ logger: false });
    app.register(capabilitiesRoutes, { db });
    await app.ready();

    const initial = await app.inject({ method: 'GET', url: '/capabilities' });
    expect(initial.statusCode).toBe(200);
    expect(initial.json()).toEqual({
      apiNamespace: 'v1',
      contracts: {
        refreshRecovery: 1,
        componentSync: 2,
        legacySplitReconciliation: 1,
        medicationBridgeCommands: 1,
        medicationBridgeSync: 1,
        medicationBridgeParentSync: 2,
        medicationBridgeAncestorSync: 3,
        medicationBridgeOccurrenceSync: 4,
        medicationBridgePrnCommands: 1,
        medicationBridgePrnSync: 5,
        // 3 adds the miss action and the missed state; builds that only know 2 must update.
        medicationCommands: 3,
        // The reviewed medication details travel with the pill. A build that
        // does not read this key keeps them on the device it reviewed them on.
        medicationDetails: 1,
      },
      bridgeUndo: true,
      recordedMiss: true,
      ledgerPrn: true,
      emailReset: 'unavailable',
      medicationLedgerActive: false,
      minimumClientBuild: 1,
      serverRelease: 'release-42',
      serverVersion: readServerVersion(),
    });

    ledgerActive = true;
    minimumClientBuild = 2;
    const changed = await app.inject({ method: 'GET', url: '/capabilities' });
    expect(changed.json()).toMatchObject({ medicationLedgerActive: true, minimumClientBuild: 2 });
    await app.close();
  });

  it('adds the latest release fields only when an update checker reports one', async () => {
    const db = {
      select: () => ({
        from: () => ({
          where: async () => [{ ledgerActivated: false, minimumClientBuild: 1, serverRelease: 'release-42' }],
        }),
      }),
    } as unknown as Db;
    const release = {
      latestServerVersion: '9.9.9',
      latestClientBuild: 12,
      latestReleaseUrl: 'https://github.com/LucaPisl/simpastil/releases/tag/v9.9.9',
    };
    const app = Fastify({ logger: false });
    app.register(capabilitiesRoutes, { db, updates: { serverVersion: '1.0.0', current: () => release } });
    await app.ready();
    const response = await app.inject({ method: 'GET', url: '/capabilities' });
    expect(response.json()).toMatchObject({ serverVersion: '1.0.0', ...release });
    await app.close();

    const bare = Fastify({ logger: false });
    bare.register(capabilitiesRoutes, { db });
    await bare.ready();
    const body = (await bare.inject({ method: 'GET', url: '/capabilities' })).json();
    expect(body).not.toHaveProperty('latestServerVersion');
    expect(body).not.toHaveProperty('latestClientBuild');
    expect(body).not.toHaveProperty('latestReleaseUrl');
    await bare.close();
  });

  it('returns a typed unavailable response when authority is absent', async () => {
    const db = {
      select: () => ({ from: () => ({ where: async () => [] }) }),
    } as unknown as Db;
    const app = Fastify({ logger: false });
    app.register(capabilitiesRoutes, { db });
    await app.ready();

    const response = await app.inject({ method: 'GET', url: '/capabilities' });
    expect(response.statusCode).toBe(503);
    expect(response.json().error.code).toBe('INTERNAL');
    await app.close();
  });
});
