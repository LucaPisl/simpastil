import type { FastifyInstance } from 'fastify';
import type { Db } from '../../db/client.js';
import { buildApp as buildApplication } from '../../app.js';
import { buildTestConfig } from './test-config.js';

export interface BuildAppOptions {
  db: Db;
  privateKey: string;
  publicKey: string;
  /** Access token TTL in seconds. Default 5 for fast token-reuse tests. */
  ttlSeconds?: number;
  /** Register the production-like global error handler (retryAfter forwarding, etc.). */
  withErrorHandler?: boolean;
  /** Override login rate limit max (default 10_000 to effectively disable in tests). */
  rateLimitMax?: number;
  /** Test-only rate-limit window in milliseconds or Fastify duration syntax. */
  rateLimitTimeWindow?: string | number;
  /** Test-only TRUSTED_PROXY_HOPS value (the production default of 1 when omitted). */
  trustedProxyHops?: number;
  /** Test-only SMTP_HOST ('' means SMTP is not configured). Defaults to configured. */
  smtpHost?: string;
  /** Test-only ADMIN_CONSOLE_DIR; no console is served when omitted. */
  adminConsoleDir?: string;
  /** Test-only environment-managed admin credentials. */
  adminCredentials?: { email: string; password: string };
  /** Test-only refresh barrier for deterministic invalidation race coverage. */
  authTestHooks?: { afterRefreshSessionLock?: () => Promise<void> };
}

/**
 * Builds a fully configured Fastify app without calling app.listen().
 * Use app.inject() to make requests in tests.
 *
 * Mirrors the registration order in src/index.ts so middleware and plugins
 * behave identically to production. Pass ttlSeconds=5 for token-reuse tests.
 */
export async function buildApp(opts: BuildAppOptions): Promise<FastifyInstance> {
  const ttl = opts.ttlSeconds ?? 5;
  const rlMax = opts.rateLimitMax ?? 10_000;
  const config = buildTestConfig({
    privateKey: opts.privateKey,
    publicKey: opts.publicKey,
    ...(opts.trustedProxyHops === undefined ? {} : { trustedProxyHops: opts.trustedProxyHops }),
    ...(opts.smtpHost === undefined ? {} : { smtpHost: opts.smtpHost }),
    ...(opts.adminConsoleDir ? { adminConsoleDir: opts.adminConsoleDir } : {}),
    ...(opts.adminCredentials ? { adminCredentials: opts.adminCredentials } : {}),
  });
  const options = {
    withErrorHandler: opts.withErrorHandler,
    rateLimitMax: rlMax,
    ...(opts.rateLimitTimeWindow === undefined ? {} : { rateLimitTimeWindow: opts.rateLimitTimeWindow }),
    forgotPasswordRateLimitMax: rlMax,
    logger: false,
    accessTokenTtlSeconds: ttl,
    ...(opts.authTestHooks ? { authTestHooks: opts.authTestHooks } : {}),
    ...(opts.withErrorHandler === undefined ? {} : { withErrorHandler: opts.withErrorHandler }),
  };
  return buildApplication(
    config,
    {
      db: opts.db,
      encryption: config.capabilities.totpCrypto,
      deliveryPayloadSealer: config.capabilities.deliveryPayloadSealer,
      deliverySubmitter: { submit: async () => {} },
    },
    options,
  );
}
