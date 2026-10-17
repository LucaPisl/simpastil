import Fastify from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { z } from 'zod';
import { readFileSync } from 'node:fs';
import { generateKeyPairSync } from 'node:crypto';
import correlationPlugin from '../../plugins/correlation.js';
import { buildApp, installErrorHandler } from '../../app.js';
import { LogsQuerySchema } from '../../modules/dose_logs/dose_logs.schema.js';
import { parseIsoDate } from '../../lib/iso-date.js';
import profilesRoutes from '../../modules/profiles/profiles.routes.js';
import { buildTestConfig } from '../helpers/test-config.js';

const apps: Array<ReturnType<typeof Fastify>> = [];

afterEach(async () => {
  await Promise.all(apps.splice(0).map((app) => app.close()));
});

describe('standardized v2 error contract', () => {
  it('returns one server correlation ID in the header, error, and safe log', async () => {
    const logLines: string[] = [];
    const app = Fastify({
      logger: { stream: { write: (line: string) => logLines.push(line) } },
      disableRequestLogging: true,
    });
    apps.push(app);
    await app.register(correlationPlugin);
    installErrorHandler(app);
    app.post('/probe', async (request) => {
      z.object({ required: z.string() }).parse(request.body);
      return { ok: true };
    });
    app.get('/logs', async (request) => LogsQuerySchema.parse(request.query));
    app.get('/date', async (request) => ({ date: parseIsoDate((request.query as { date: string }).date) }));
    await app.ready();

    const response = await app.inject({
      method: 'POST',
      url: '/probe?token=reset-fragment-sentinel',
      headers: {
        // Too long to be accepted as an opaque correlation identifier.
        'x-correlation-id': 'client-supplied-'.repeat(20),
      },
      body: {
        email: 'person@example.invalid',
        profileName: 'profile-sentinel',
        pillName: 'pill-sentinel',
        authorization: 'eyJhbGciOiJSUzI1NiJ9.jwt-secret-sentinel',
        apiKey: 'sk_live_api-key-sentinel',
        body: 'raw-body-sentinel',
      },
    });

    expect(response.statusCode).toBe(400);
    const headerCorrelation = response.headers['x-correlation-id'];
    expect(headerCorrelation).toMatch(/^[0-9a-f-]{36}$/);
    const body = response.json<{ error: {
      code: string;
      message: string;
      retryable: boolean;
      correlationId: string;
      details: Record<string, unknown>;
    } }>();
    expect(body.error).toMatchObject({
      code: 'VALIDATION_ERROR',
      message: 'Request validation failed',
      retryable: false,
      correlationId: headerCorrelation,
      details: {},
    });

    const logs = logLines.join('');
    expect(logs).toContain(String(headerCorrelation));
    for (const sentinel of [
      'reset-fragment-sentinel',
      'person@example.invalid',
      'profile-sentinel',
      'pill-sentinel',
      'jwt-secret-sentinel',
      'api-key-sentinel',
      'raw-body-sentinel',
    ]) {
      expect(response.body).not.toContain(sentinel);
      expect(logs).not.toContain(sentinel);
    }
  });

  it('sanitizes not-found and semantic route failures with correlated 4xx responses', async () => {
    const logLines: string[] = [];
    const app = Fastify({
      logger: { stream: { write: (line: string) => logLines.push(line) } },
      disableRequestLogging: true,
    });
    apps.push(app);
    await app.register(correlationPlugin);
    installErrorHandler(app);
    app.get('/logs', async (request) => LogsQuerySchema.parse(request.query));
    app.get('/date', async (request) => ({ date: parseIsoDate((request.query as { date: string }).date) }));
    await app.ready();

    const missing = await app.inject({
      method: 'GET',
      url: '/not-a-real-route?token=not-found-query-sentinel',
    });
    expect(missing.statusCode).toBe(404);
    expect(missing.headers['x-correlation-id']).toMatch(/^[0-9a-f-]{36}$/);
    expect(missing.json().error.correlationId).toBe(missing.headers['x-correlation-id']);
    expect(missing.body).not.toContain('not-found-query-sentinel');

    const reversed = await app.inject({
      method: 'GET',
      url: '/logs?from=2026-05-02&to=2026-05-01&token=range-query-sentinel',
    });
    expect(reversed.statusCode).toBe(400);
    expect(reversed.json().error.code).toBe('VALIDATION_ERROR');
    expect(reversed.body).not.toContain('range-query-sentinel');

    const invalidDate = await app.inject({
      method: 'GET',
      url: '/date?date=2026-04-31&token=date-query-sentinel',
    });
    expect(invalidDate.statusCode).toBe(400);
    expect(invalidDate.json().error.code).toBe('VALIDATION_ERROR');
    expect(invalidDate.body).not.toContain('date-query-sentinel');

    const eventLogs = logLines.join('');
    expect(eventLogs).toContain(String(missing.headers['x-correlation-id']));
    expect(eventLogs).toContain(String(reversed.headers['x-correlation-id']));
    expect(eventLogs).toContain(String(invalidDate.headers['x-correlation-id']));
    for (const sentinel of ['not-found-query-sentinel', 'range-query-sentinel', 'date-query-sentinel']) {
      expect(eventLogs).not.toContain(sentinel);
    }
  });

  it('keeps proxy access and error logging path-free for throttling and upstream failures', () => {
    const nginx = readFileSync(new URL('../../../../nginx/nginx.conf', import.meta.url), 'utf8');
    const safeFormat = nginx.match(/log_format safe[\s\S]*?;/)?.[0] ?? '';
    const errorLogDirectives = nginx.match(/^\s*error_log\s+[^;]+;/gm) ?? [];
    expect(errorLogDirectives).toEqual(['error_log  /dev/null emerg;']);
    for (const failurePathCanary of [
      'limit_req_status 429;',
      'proxy_connect_timeout 5s;',
      'proxy_read_timeout 30s;',
      'proxy_send_timeout 30s;',
    ]) {
      expect(nginx).toContain(failurePathCanary);
    }
    for (const forbidden of ['$request ', '$request_uri', '$uri', '$request_body', '$http_']) {
      expect(safeFormat).not.toContain(forbidden);
    }
    expect(safeFormat).toContain('$upstream_http_x_correlation_id');
  });

  it('logs one safe correlated event for an actual resource validation failure', async () => {
    const logLines: string[] = [];
    const app = Fastify({
      logger: { stream: { write: (line: string) => logLines.push(line) } },
      disableRequestLogging: true,
    });
    apps.push(app);
    await app.register(correlationPlugin);
    app.decorate('apiKeyGuardRegistered', async () => {});
    app.decorate('clientBuildGate', async () => {});
    app.decorate('authenticate', async (request: { user?: unknown }) => {
      request.user = { userId: '00000000-0000-4000-8000-000000000001' };
    });
    await app.register(profilesRoutes, { db: {} as never });
    installErrorHandler(app);
    await app.ready();

    const response = await app.inject({
      method: 'POST',
      url: '/profiles',
      body: { name: '', sentinel: 'profile-validation-sentinel' },
    });
    expect(response.statusCode).toBe(400);
    const correlationId = String(response.headers['x-correlation-id']);
    expect(response.json().error.correlationId).toBe(correlationId);
    expect(response.body).not.toContain('profile-validation-sentinel');
    const records = logLines
      .flatMap((line) => line.trim().split('\n'))
      .filter(Boolean)
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    const matchingLogs = records.filter((record) => (
      record['event'] === 'request.error' && record['correlationId'] === correlationId
    ));
    expect(matchingLogs).toHaveLength(1);
    expect(logLines.join('')).not.toContain('profile-validation-sentinel');
  });

  it('routes malformed URLs through the buildApp framework-error boundary', async () => {
    const { privateKey, publicKey } = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    });
    const config = buildTestConfig({ privateKey, publicKey });
    const logLines: string[] = [];
    const app = await buildApp(
      config,
      {
        db: {} as never,
        encryption: config.capabilities.totpCrypto,
        deliveryPayloadSealer: config.capabilities.deliveryPayloadSealer,
        deliverySubmitter: { submit: async () => {} },
      },
      { logger: { stream: { write: (line: string) => logLines.push(line) } } },
    );
    apps.push(app);

    const response = await app.inject({
      method: 'GET',
      url: '/api/v1/%E0%A4%A?token=malformed-query-sentinel',
    });
    expect(response.statusCode).toBe(400);
    const correlationId = String(response.headers['x-correlation-id']);
    expect(correlationId).toMatch(/^[0-9a-f-]{36}$/);
    expect(response.json().error).toMatchObject({
      code: 'VALIDATION_ERROR',
      correlationId,
    });
    expect(response.body).not.toContain('malformed-query-sentinel');

    const records = logLines
      .flatMap((line) => line.trim().split('\n'))
      .filter(Boolean)
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    const matchingLogs = records.filter((record) => (
      record['event'] === 'request.error' && record['correlationId'] === correlationId
    ));
    expect(matchingLogs).toHaveLength(1);
    expect(logLines.join('')).not.toContain('malformed-query-sentinel');
  });
});
