import { describe, it, expect, afterEach } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs } from '../helpers/db-helpers.js';
import { trustProxyForHops } from '../../app.js';

const SOCKET_PEER = '192.0.2.1';

describe('trustProxyForHops: request.ip after exactly N trusted hops', () => {
  const apps: FastifyInstance[] = [];
  afterEach(async () => {
    await Promise.all(apps.splice(0).map((app) => app.close()));
  });

  async function resolveIp(hops: number, forwardedFor: string | string[] | undefined): Promise<{ ip: string; ips: string[] }> {
    const app = Fastify({ logger: false, trustProxy: trustProxyForHops(hops) });
    apps.push(app);
    app.get('/ip', async (request) => ({ ip: request.ip, ips: request.ips }));
    await app.ready();
    const response = await app.inject({
      method: 'GET',
      url: '/ip',
      remoteAddress: SOCKET_PEER,
      ...(forwardedFor === undefined ? {} : { headers: { 'x-forwarded-for': forwardedFor } }),
    });
    return response.json<{ ip: string; ips: string[] }>();
  }

  // A client-controlled prefix, the real client, then two proxies that each
  // append the address they received the request from.
  const chain = '198.51.100.250, 203.0.113.7, 10.0.0.2, 10.0.0.1';

  it('0 hops ignores X-Forwarded-For and uses the socket peer', async () => {
    expect((await resolveIp(0, chain)).ip).toBe(SOCKET_PEER);
    expect((await resolveIp(0, undefined)).ip).toBe(SOCKET_PEER);
  });

  it('1 hop uses the last X-Forwarded-For entry', async () => {
    expect((await resolveIp(1, chain)).ip).toBe('10.0.0.1');
    expect((await resolveIp(1, '203.0.113.7')).ip).toBe('203.0.113.7');
  });

  it('2 hops uses the second-to-last X-Forwarded-For entry', async () => {
    expect((await resolveIp(2, chain)).ip).toBe('10.0.0.2');
    expect((await resolveIp(2, '203.0.113.7, 10.0.0.1')).ip).toBe('203.0.113.7');
  });

  it('never lets a client-supplied prefix beyond the trusted hops choose request.ip', async () => {
    for (const hops of [1, 2]) {
      const a = await resolveIp(hops, `198.51.100.1, ${chain}`);
      const b = await resolveIp(hops, `198.51.100.2, 198.51.100.3, ${chain}`);
      expect(a.ip).toBe(b.ip);
    }
  });

  it('falls back to the socket peer when the header is absent', async () => {
    for (const hops of [0, 1, 2]) expect((await resolveIp(hops, undefined)).ip).toBe(SOCKET_PEER);
  });

  it('uses the last X-Forwarded-For header when it is sent more than once', async () => {
    expect((await resolveIp(1, ['198.51.100.9', '203.0.113.7'])).ip).toBe('203.0.113.7');
  });

  it('rejects a hop count that is not a non-negative integer', () => {
    for (const bad of [-1, 1.5, Number.NaN]) {
      expect(() => trustProxyForHops(bad)).toThrow(/non-negative integer/);
    }
  });
});

describe('buildApp keys rate limits on the address TRUSTED_PROXY_HOPS hops away', () => {
  const MAX = 3;
  let app: FastifyInstance | undefined;
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await app?.close();
    await cleanup?.();
    app = undefined;
    cleanup = undefined;
  });

  async function start(hops: number): Promise<FastifyInstance> {
    const dbs = createDbs();
    cleanup = dbs.cleanup;
    app = await buildApp({
      db: dbs.appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      withErrorHandler: true,
      rateLimitMax: MAX,
      trustedProxyHops: hops,
    });
    return app;
  }

  async function statuses(instance: FastifyInstance, forwardedFor: (attempt: number) => string): Promise<number[]> {
    const result: number[] = [];
    for (let attempt = 0; attempt < MAX + 2; attempt += 1) {
      const response = await instance.inject({
        method: 'POST',
        url: '/api/v1/auth/login',
        headers: { 'X-Forwarded-For': forwardedFor(attempt) },
        payload: { email: 'nobody@example.com', password: 'password1234' },
      });
      result.push(response.statusCode);
    }
    return result;
  }

  it('0 hops: every X-Forwarded-For value shares the socket-peer bucket', async () => {
    const instance = await start(0);
    const result = await statuses(instance, (attempt) => `198.51.100.${attempt + 1}`);
    expect(result.slice(0, MAX)).not.toContain(429);
    expect(result.slice(MAX)).toEqual([429, 429]);
  });

  it('1 hop: distinct trailing addresses get distinct buckets, a forged prefix does not', async () => {
    const instance = await start(1);
    const forgedPrefix = await statuses(instance, (attempt) => `198.51.100.${attempt + 1}, 203.0.113.9`);
    expect(forgedPrefix.slice(0, MAX)).not.toContain(429);
    expect(forgedPrefix.slice(MAX)).toEqual([429, 429]);
    const other = await statuses(instance, () => '203.0.113.10');
    expect(other[0]).not.toBe(429);
  });

  it('2 hops: the client address is the second-to-last entry', async () => {
    const instance = await start(2);
    const forgedPrefix = await statuses(instance, (attempt) => `198.51.100.${attempt + 1}, 203.0.113.9, 10.0.0.1`);
    expect(forgedPrefix.slice(0, MAX)).not.toContain(429);
    expect(forgedPrefix.slice(MAX)).toEqual([429, 429]);
    const otherClient = await statuses(instance, () => '203.0.113.10, 10.0.0.1');
    expect(otherClient[0]).not.toBe(429);
  });
});
