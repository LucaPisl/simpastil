import Fastify, { type FastifyInstance, type FastifyLoggerOptions, type FastifyReply, type FastifyRequest } from 'fastify';
import jwtPlugin from '@fastify/jwt';
import cors from '@fastify/cors';
import type { ApiConfig } from './config/app-config.js';
import type { Db } from './db/client.js';
import type { EncryptionCapabilities } from './lib/crypto.js';
import type { DeliveryPayloadSealer } from './lib/delivery-payload-crypto.js';
import type { DeliverySubmitter } from './lib/delivery.js';
import authenticatePlugin from './plugins/authenticate.js';
import apiKeyGuardPlugin from './plugins/api-key-guard.js';
import clientBuildGatePlugin from './plugins/client-build-gate.js';
import adminRoutes from './modules/admin/admin.routes.js';
import authRoutes from './modules/auth/auth.routes.js';
import recoveryRoutes from './modules/recovery/recovery.routes.js';
import deviceRoutes from './modules/auth/device.routes.js';
import profilesRoutes from './modules/profiles/profiles.routes.js';
import pillsRoutes from './modules/pills/pills.routes.js';
import schedulesRoutes from './modules/schedules/schedules.routes.js';
import doseLogsRoutes from './modules/dose_logs/dose_logs.routes.js';
import medicationRoutes from './modules/medication/medication.routes.js';
import capabilitiesRoutes, { type CapabilitiesUpdates } from './modules/capabilities/capabilities.routes.js';
import syncRoutes from './modules/sync/sync.routes.js';
import healthRoutes from './modules/health/health.routes.js';
import correlationPlugin, { CORRELATION_HEADER, createCorrelationId, resolveCorrelationId } from './plugins/correlation.js';
import { ApiError, serializeApiError } from './modules/shared/api-error.js';
import { ErrorCode } from './modules/shared/errors.js';
import { SafeLogger } from './lib/safe-logger.js';
import { SessionService } from './modules/auth/session.service.js';

export interface BuildAppDependencies {
  db: Db;
  encryption: EncryptionCapabilities;
  deliveryPayloadSealer: DeliveryPayloadSealer;
  /** @deprecated Kept optional for older app-factory callers; delivery is persisted through the outbox. */
  deliverySubmitter?: DeliverySubmitter;
  sessionService?: SessionService;
  /** Latest-release lookup behind GET /capabilities; omitted means no update information. */
  updates?: CapabilitiesUpdates;
}

export interface BuildAppOptions {
  withErrorHandler?: boolean;
  rateLimitMax?: number;
  /** Test-only override for deterministic rate-limit window recovery. */
  rateLimitTimeWindow?: string | number;
  forgotPasswordRateLimitMax?: number;
  /** Test-only override; production values come from the validated config. */
  accessTokenTtlSeconds?: number;
  /** Test-only refresh barrier for deterministic invalidation race coverage. */
  authTestHooks?: { afterRefreshSessionLock?: () => Promise<void> };
  logger?: boolean | FastifyLoggerOptions;
}

export function installErrorHandler(app: FastifyInstance): void {
  const logger = new SafeLogger({
    info: (record) => app.log.info(record),
    warn: (record) => app.log.warn(record),
    error: (record) => app.log.error(record),
  });

  const handleError = (error: unknown, request: FastifyRequest, reply: FastifyReply) => {
    const correlationId = request.correlationId || createCorrelationId();
    reply.header(CORRELATION_HEADER, correlationId);
    const apiError = ApiError.fromUnknown(error);
    logger.error('request.error', {
      correlationId,
      method: request.method,
      ...(request.routeOptions.url ? { route: request.routeOptions.url } : {}),
      statusCode: apiError.statusCode,
      errorCode: apiError.code,
      retryable: apiError.retryable,
    });

    // Keep the existing v1 rate-limit body readable for current clients. The
    // response still carries the server correlation header; all new semantic
    // validation and internal failures use the versioned nested contract.
    if (apiError.code === ErrorCode.RATE_LIMIT_EXCEEDED) {
      const retryAfter = apiError.details['retryAfter'];
      return reply.status(apiError.statusCode).send({
        error: apiError.message,
        code: apiError.code,
        ...(typeof retryAfter === 'number' ? { retryAfter } : {}),
        correlationId,
      });
    }
    return reply.status(apiError.statusCode).send(serializeApiError(apiError, correlationId));
  };

  app.setErrorHandler(handleError);
  app.setNotFoundHandler((request, reply) => handleError(
    new ApiError(404, ErrorCode.RESOURCE_NOT_FOUND, 'Resource not found', { retryable: false }),
    request,
    reply,
  ));
}

function safeFastifyLogger(custom?: FastifyLoggerOptions): FastifyLoggerOptions {
  return {
    ...custom,
    level: 'info',
    serializers: {
      // Fastify's default request serializer includes the raw URL. Keep the
      // serializer intentionally smaller so query strings and headers never
      // enter application logs.
      req: (request) => ({ method: request.method }),
      res: (response) => ({ statusCode: response.statusCode }),
      // Error messages can include parser details or user-controlled input;
      // the application error handler emits only a typed safe event.
      err: () => ({ type: 'Error', message: 'request failed', stack: 'redacted' }),
    },
  };
}

function frameworkErrorHandler(
  error: unknown,
  request: FastifyRequest,
  reply: FastifyReply,
): void {
  const correlationId = resolveCorrelationId(request.headers[CORRELATION_HEADER]);
  reply.header(CORRELATION_HEADER, correlationId);
  const apiError = ApiError.fromUnknown(error);
  const logger = new SafeLogger({
    info: (record) => request.log.info(record),
    warn: (record) => request.log.warn(record),
    error: (record) => request.log.error(record),
  });
  logger.error('request.error', {
    correlationId,
    method: request.method,
    ...(request.routeOptions?.url ? { route: request.routeOptions.url } : {}),
    statusCode: apiError.statusCode,
    errorCode: apiError.code,
    retryable: apiError.retryable,
  });
  void reply.status(apiError.statusCode).send(apiError.toResponse(correlationId));
}

function accessTokenTtl(config: ApiConfig, options: BuildAppOptions): number {
  const override = options.accessTokenTtlSeconds;
  if (override === undefined) return config.jwt.accessTokenTtlSeconds;
  if (config.nodeEnv !== 'test') {
    throw new Error('accessTokenTtlSeconds overrides are only available in test environments');
  }
  if (!Number.isSafeInteger(override) || override < 1 || override > 3600) {
    throw new Error('test accessTokenTtlSeconds must be an integer from 1 through 3600');
  }
  return override;
}

export async function buildApp(
  config: ApiConfig,
  dependencies: BuildAppDependencies,
  options: BuildAppOptions = {},
): Promise<FastifyInstance> {
  const ttlSeconds = accessTokenTtl(config, options);
  const sessionService = dependencies.sessionService
    ?? new SessionService(dependencies.db, { environmentManagedAdmin: config.admin !== undefined });
  if (!dependencies.sessionService && config.admin) {
    await sessionService.initializeEnvironmentManagedAdmin();
  }
  const app = Fastify({
    logger: options.logger === false
      ? false
      : safeFastifyLogger(typeof options.logger === 'object' ? options.logger : undefined),
    frameworkErrors: frameworkErrorHandler,
    disableRequestLogging: true,
    requestTimeout: config.requestTimeoutMs,
    // Trust only the configured number of proxy hops so a client-supplied
    // X-Forwarded-For prefix can never choose request.ip (rate-limit key).
    trustProxy: config.trustedProxyHops,
  });

  if (config.trustedProxyHops > 0) {
    // Without X-Forwarded-For every client resolves to the proxy's address and
    // shares one rate-limit bucket. Warn once, with a static message only
    // (the logging contract forbids addresses and headers).
    let warnedMissingForwardedFor = false;
    app.addHook('onRequest', async (request) => {
      if (warnedMissingForwardedFor || request.headers['x-forwarded-for'] !== undefined) return;
      warnedMissingForwardedFor = true;
      request.log.warn(
        'TRUSTED_PROXY_HOPS > 0 but a request arrived without X-Forwarded-For; '
        + 'all such clients share one rate-limit bucket. Make the front proxy set '
        + 'X-Forwarded-For, or set TRUSTED_PROXY_HOPS=0 if the API is exposed directly.',
      );
    });
  }

  await app.register(correlationPlugin);
  if (options.withErrorHandler !== false) installErrorHandler(app);

  // Preserve the v1 client compatibility contract for body-less DELETEs.
  app.addHook('onRequest', async (request) => {
    const contentLength = request.headers['content-length'];
    if (request.method === 'DELETE' && (!contentLength || contentLength === '0')) {
      delete request.headers['content-type'];
    }
  });

  await app.register(cors, { origin: config.corsOrigins });
  await app.register(jwtPlugin, {
    secret: { private: config.jwt.privateKey, public: config.jwt.publicKey },
    sign: { algorithm: 'RS256', expiresIn: ttlSeconds },
    verify: { clockTolerance: 15 },
  });

  await app.register(authenticatePlugin, { db: dependencies.db, sessionService });
  await app.register(apiKeyGuardPlugin, { db: dependencies.db });
  await app.register(clientBuildGatePlugin, { db: dependencies.db });
  await app.register(adminRoutes, {
    db: dependencies.db,
    config,
    crypto: dependencies.encryption,
    payloadSealer: dependencies.deliveryPayloadSealer,
    sessionService,
    ttlSeconds,
    ...(options.rateLimitMax === undefined ? {} : { rateLimitMax: options.rateLimitMax }),
    ...(options.rateLimitTimeWindow === undefined ? {} : { rateLimitTimeWindow: options.rateLimitTimeWindow }),
    prefix: '/api/v1',
  });
  await app.register(authRoutes, {
    db: dependencies.db,
    config,
    crypto: dependencies.encryption,
    sessionService,
    ttlSeconds,
    ...(options.rateLimitMax === undefined ? {} : { rateLimitMax: options.rateLimitMax }),
    ...(options.rateLimitTimeWindow === undefined ? {} : { rateLimitTimeWindow: options.rateLimitTimeWindow }),
    ...(options.authTestHooks ? { testHooks: options.authTestHooks } : {}),
    prefix: '/api/v1',
  });
  await app.register(recoveryRoutes, {
    db: dependencies.db,
    config,
    encryption: dependencies.encryption,
    payloadSealer: dependencies.deliveryPayloadSealer,
    sessionService,
    ...(options.rateLimitMax === undefined ? {} : { rateLimitMax: options.rateLimitMax }),
    ...(options.rateLimitTimeWindow === undefined ? {} : { rateLimitTimeWindow: options.rateLimitTimeWindow }),
    ...(options.forgotPasswordRateLimitMax === undefined ? {} : { forgotPasswordRateLimitMax: options.forgotPasswordRateLimitMax }),
    prefix: '/api/v1',
  });
  await app.register(deviceRoutes, { db: dependencies.db, prefix: '/api/v1' });
  await app.register(capabilitiesRoutes, {
    db: dependencies.db,
    ...(dependencies.updates ? { updates: dependencies.updates } : {}),
    prefix: '/api/v1',
  });
  await app.register(profilesRoutes, { db: dependencies.db, prefix: '/api/v1' });
  await app.register(pillsRoutes, { db: dependencies.db, prefix: '/api/v1' });
  await app.register(schedulesRoutes, { db: dependencies.db, prefix: '/api/v1' });
  await app.register(doseLogsRoutes, { db: dependencies.db, prefix: '/api/v1' });
  await app.register(medicationRoutes, { db: dependencies.db, prefix: '/api/v1' });
  await app.register(syncRoutes, { db: dependencies.db, cursorSecret: config.jwt.privateKey, prefix: '/api/v1' });
  await app.register(healthRoutes, { db: dependencies.db, config, prefix: '/api/v1' });

  await app.ready();
  return app;
}
