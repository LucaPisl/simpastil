import { loadAppConfig, readRuntimeEnvironment, type ApiConfig } from './config/app-config.js';
import { buildApp } from './app.js';
import { createDatabase } from './db/client.js';
import { startTokenGc } from './lib/token-gc.js';
import { SessionService } from './modules/auth/session.service.js';
import { createLifecycleCoordinator } from './runtime/lifecycle.js';
import { logProcessEvent } from './lib/process-log.js';
import { SafeLogger } from './lib/safe-logger.js';
import { readServerVersion, UpdateChecker } from './modules/updates/update-checker.js';

const loadedConfig = loadAppConfig(readRuntimeEnvironment(), 'api');
if (loadedConfig.role !== 'api') throw new Error('API entrypoint requires an API runtime configuration');
const config: ApiConfig = loadedConfig;
const database = createDatabase(config.database);
const sessionService = new SessionService(database.db, { environmentManagedAdmin: config.admin !== undefined });
if (config.admin) await sessionService.initializeEnvironmentManagedAdmin();
const serverVersion = readServerVersion();
let updateChecker: UpdateChecker | undefined;
const app = await buildApp(
  config,
  {
    db: database.db,
    encryption: config.capabilities.totpCrypto,
    deliveryPayloadSealer: config.capabilities.deliveryPayloadSealer,
    sessionService,
    updates: { serverVersion, current: () => updateChecker?.current() },
  },
);

await app.listen({ port: config.port, host: '0.0.0.0' });
const stopTokenGc = startTokenGc(database.db);
if (config.updateCheck) {
  updateChecker = new UpdateChecker({
    currentServerVersion: serverVersion,
    logger: new SafeLogger({
      info: (record) => app.log.info(record),
      warn: (record) => app.log.warn(record),
      error: (record) => app.log.error(record),
    }),
  });
}
const updateTimer = updateChecker?.start();

const lifecycle = createLifecycleCoordinator({
  timeoutMs: config.shutdownTimeoutMs,
  stopWork: (deadlineMs) => {
    updateTimer?.stop();
    return stopTokenGc.drain(deadlineMs);
  },
  stopAccepting: () => app.close(),
  forceClose: () => app.server.closeAllConnections(),
  closeResources: async (remainingMs) => {
    await database.sql.end({ timeout: Math.max(1, Math.ceil(remainingMs / 1_000)) });
  },
});

for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.once(signal, () => {
    logProcessEvent('info', 'process.shutdown_started', { signal });
    void lifecycle.shutdown().then(
      (clean) => { process.exitCode = clean ? 0 : 1; },
      () => { process.exitCode = 1; },
    );
  });
}
