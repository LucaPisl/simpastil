import { describe, it, expect, beforeAll, afterAll, vi } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs } from '../helpers/db-helpers.js';

describe('X-Forwarded-For handling', () => {
  let app: FastifyInstance;
  let cleanup: () => Promise<void>;

  beforeAll(async () => {
    const dbs = createDbs();
    cleanup = dbs.cleanup;
    app = await buildApp({
      db: dbs.appDb,
      privateKey: process.env['JWT_PRIVATE_KEY']!,
      publicKey: process.env['JWT_PUBLIC_KEY']!,
      withErrorHandler: true,
      rateLimitMax: 3,
    });
  });

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  it('keeps the proxy-appended client address as the rate-limit key when the client forges a prefix', async () => {
    const statuses: number[] = [];
    for (let attempt = 0; attempt < 6; attempt += 1) {
      // A proxy appends the real peer; the client controls everything before it.
      const response = await app.inject({
        method: 'POST',
        url: '/api/v1/auth/login',
        headers: { 'X-Forwarded-For': `198.51.100.${attempt + 1}, 203.0.113.9` },
        payload: { email: 'nobody@example.com', password: 'password1234' },
      });
      statuses.push(response.statusCode);
    }
    expect(statuses.slice(0, 3)).not.toContain(429);
    expect(statuses.slice(3)).toEqual([429, 429, 429]);
  });

  function login(headers: Record<string, string | string[]>) {
    return app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      headers,
      payload: { email: 'nobody@example.com', password: 'password1234' },
    });
  }

  async function exhaust(headers: Record<string, string | string[]>): Promise<number[]> {
    const statuses: number[] = [];
    for (let attempt = 0; attempt < 5; attempt += 1) statuses.push((await login(headers)).statusCode);
    return statuses;
  }

  it('keys on the last forwarded address when X-Forwarded-For is sent as multiple headers', async () => {
    const spoofed = (n: number) => ['198.51.100.' + n, '203.0.113.50'];
    const statuses: number[] = [];
    for (let attempt = 0; attempt < 5; attempt += 1) {
      statuses.push((await login({ 'X-Forwarded-For': spoofed(attempt + 1) })).statusCode);
    }
    expect(statuses.slice(0, 3)).not.toContain(429);
    expect(statuses.slice(3)).toEqual([429, 429]);
    // A different appended peer is a different bucket.
    expect((await login({ 'X-Forwarded-For': ['198.51.100.1', '203.0.113.51'] })).statusCode).not.toBe(429);
  });

  it('falls back to the socket peer when X-Forwarded-For is absent and warns once', async () => {
    const warn = vi.spyOn(app.log, 'warn');
    const statuses = await exhaust({});
    expect(statuses.slice(0, 3)).not.toContain(429);
    expect(statuses.slice(3)).toEqual([429, 429]);
    // A forwarded client is a separate bucket from the socket-peer bucket.
    expect((await login({ 'X-Forwarded-For': '203.0.113.77' })).statusCode).not.toBe(429);
    expect(warn).toHaveBeenCalledTimes(1);
    warn.mockRestore();
  });
});
