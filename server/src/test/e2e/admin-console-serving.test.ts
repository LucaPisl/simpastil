import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { buildApp } from '../helpers/app-factory.js';
import { createDbs } from '../helpers/db-helpers.js';
import { ADMIN_CONSOLE_SECURITY_HEADERS, API_SECURITY_HEADERS } from '../../plugins/admin-console.js';

const SECRET = 'outside-the-console-directory';

describe('API serves the admin console', () => {
  let app: FastifyInstance;
  let plainApp: FastifyInstance;
  let cleanup: () => Promise<void>;
  let scratch: string;

  beforeAll(async () => {
    scratch = await mkdtemp(path.join(tmpdir(), 'simpastil-console-'));
    const dist = path.join(scratch, 'public');
    await mkdir(path.join(dist, 'assets'), { recursive: true });
    await writeFile(path.join(dist, 'index.html'), '<!doctype html><title>Simpastil Admin</title>');
    await writeFile(path.join(dist, 'assets', 'index-abc123.js'), 'console.log("console")');
    await writeFile(path.join(dist, 'assets', 'index-abc123.js.map'), '{}');
    await writeFile(path.join(dist, '.hidden'), 'hidden');
    await writeFile(path.join(scratch, 'secret.txt'), SECRET);

    const created = createDbs();
    cleanup = created.cleanup;
    const keys = { privateKey: process.env['JWT_PRIVATE_KEY']!, publicKey: process.env['JWT_PUBLIC_KEY']! };
    app = await buildApp({ db: created.appDb, ...keys, adminConsoleDir: dist });
    plainApp = await buildApp({ db: created.appDb, ...keys });
  });

  afterAll(async () => {
    await app.close();
    await plainApp.close();
    await cleanup();
    await rm(scratch, { recursive: true, force: true });
  });

  function expectHeaders(headers: Record<string, unknown>, expected: Readonly<Record<string, string>>): void {
    for (const [name, value] of Object.entries(expected)) expect(headers[name]).toBe(value);
    expect(headers['strict-transport-security']).toBeUndefined();
  }

  it('serves the index at / with the console header set', async () => {
    const response = await app.inject({ method: 'GET', url: '/' });
    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toBe('text/html; charset=utf-8');
    expect(response.headers['cache-control']).toBe('no-cache');
    expect(response.body).toContain('Simpastil Admin');
    expectHeaders(response.headers, ADMIN_CONSOLE_SECURITY_HEADERS);
    expect(response.headers['content-security-policy']).toContain("script-src 'self'");
    expect(response.headers['permissions-policy']).toContain('camera=()');
    expect(response.headers['cross-origin-opener-policy']).toBe('same-origin');
    expect((await app.inject({ method: 'GET', url: '/index.html' })).statusCode).toBe(200);
  });

  it('serves hashed assets as immutable, with the console header set and conditional requests', async () => {
    const response = await app.inject({ method: 'GET', url: '/assets/index-abc123.js' });
    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toBe('text/javascript; charset=utf-8');
    expect(response.headers['cache-control']).toBe('public, max-age=31536000, immutable');
    expectHeaders(response.headers, ADMIN_CONSOLE_SECURITY_HEADERS);
    const etag = String(response.headers['etag']);
    const conditional = await app.inject({
      method: 'GET',
      url: '/assets/index-abc123.js',
      headers: { 'if-none-match': etag },
    });
    expect(conditional.statusCode).toBe(304);
  });

  it('answers HEAD and rejects other methods on console paths', async () => {
    const head = await app.inject({ method: 'HEAD', url: '/' });
    expect(head.statusCode).toBe(200);
    expect(head.body).toBe('');
    for (const method of ['POST', 'PUT', 'DELETE', 'PATCH'] as const) {
      const response = await app.inject({ method, url: '/', payload: '{}', headers: { 'content-type': 'application/json' } });
      expect(response.statusCode).toBe(404);
      expectHeaders(response.headers, API_SECURITY_HEADERS);
    }
  });

  it('never serves files outside the allowlist or traverses paths', async () => {
    const urls = [
      '/../secret.txt',
      '/..%2fsecret.txt',
      '/%2e%2e/secret.txt',
      '/assets/../../secret.txt',
      '/assets/%2e%2e/%2e%2e/secret.txt',
      '/assets/..%2f..%2fsecret.txt',
      '/secret.txt',
      '/.hidden',
      '/assets/index-abc123.js.map',
      '/assets/',
      '/assets',
      '/nope',
    ];
    for (const url of urls) {
      const response = await app.inject({ method: 'GET', url });
      expect(response.statusCode, url).toBe(404);
      expect(response.body, url).not.toContain(SECRET);
      expectHeaders(response.headers, API_SECURITY_HEADERS);
    }
  });

  it('leaves the API namespace alone and gives it the strict API header set', async () => {
    const live = await app.inject({ method: 'GET', url: '/api/v1/health/live' });
    expect(live.statusCode).toBe(200);
    expectHeaders(live.headers, API_SECURITY_HEADERS);
    expect(live.headers['permissions-policy']).toBeUndefined();

    const capabilities = await app.inject({ method: 'GET', url: '/api/v1/capabilities' });
    expect(capabilities.statusCode).toBe(200);
    expectHeaders(capabilities.headers, API_SECURITY_HEADERS);

    const missing = await app.inject({ method: 'GET', url: '/api/v1/definitely-missing' });
    expect(missing.statusCode).toBe(404);
    expect(missing.json<{ error: { code: string } }>().error.code).toBe('RESOURCE_NOT_FOUND');
    expectHeaders(missing.headers, API_SECURITY_HEADERS);

    const index = await app.inject({ method: 'GET', url: '/api/index.html' });
    expect(index.statusCode).toBe(404);
  });

  it('serves no console and a plain 404 at / when no directory is configured', async () => {
    const response = await plainApp.inject({ method: 'GET', url: '/' });
    expect(response.statusCode).toBe(404);
    expectHeaders(response.headers, API_SECURITY_HEADERS);
    const live = await plainApp.inject({ method: 'GET', url: '/api/v1/health/live' });
    expectHeaders(live.headers, API_SECURITY_HEADERS);
  });
});
