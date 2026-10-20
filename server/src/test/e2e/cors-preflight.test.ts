import { generateKeyPairSync } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { Db } from '../../db/client.js';
import { buildApp } from '../helpers/app-factory.js';

const ALLOWED = 'https://console.example.test';
const DISALLOWED = 'https://evil.example.test';

describe('CORS preflight', () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    const { privateKey, publicKey } = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    });
    // A preflight never reaches a handler, so no database is needed.
    app = await buildApp({ db: {} as Db, privateKey, publicKey, corsOrigin: ALLOWED });
  });

  afterAll(async () => {
    await app.close();
  });

  function preflight(origin: string, method: string, url = '/api/v1/admin/settings') {
    return app.inject({
      method: 'OPTIONS',
      url,
      headers: {
        origin,
        'access-control-request-method': method,
        'access-control-request-headers': 'authorization,content-type',
      },
    });
  }

  it.each(['GET', 'POST', 'PUT', 'PATCH', 'DELETE'])('allows %s from a listed origin', async (method) => {
    const response = await preflight(ALLOWED, method);
    expect(response.statusCode).toBe(204);
    expect(response.headers['access-control-allow-origin']).toBe(ALLOWED);
    const allowed = String(response.headers['access-control-allow-methods']).split(',').map((m) => m.trim());
    expect(allowed).toEqual(expect.arrayContaining(['PUT', 'PATCH', 'DELETE']));
  });

  it('sends no allow-origin to an unlisted origin, so the browser blocks PUT and DELETE', async () => {
    for (const method of ['PUT', 'DELETE']) {
      const response = await preflight(DISALLOWED, method);
      expect(response.headers['access-control-allow-origin']).toBeUndefined();
    }
  });
});
