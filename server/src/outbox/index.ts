import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import postgres from 'postgres';
import { PostgresOutboxRepository } from './outbox-repository.js';
import { OutboxWorker } from './outbox-worker.js';
import { createSmtpDelivery } from './smtp-delivery.js';
import { loadOutboxWorkerConfig } from './worker-config.js';
import { createLifecycleCoordinator } from '../runtime/lifecycle.js';
import { logProcessEvent } from '../lib/process-log.js';

export async function runOutboxWorker(): Promise<void> {
  const config = loadOutboxWorkerConfig();
  const sql = postgres(config.databaseUrl, {
    max: config.maxConnections,
    connect_timeout: 10,
    idle_timeout: 30,
    max_lifetime: 1800,
    connection: { statement_timeout: 30_000 },
  });
  const repository = new PostgresOutboxRepository(sql);
  const delivery = createSmtpDelivery(config.smtp);
  const worker = new OutboxWorker({
    repository,
    payloadOpener: config.payloadOpener,
    delivery,
    publicAppUrl: config.publicAppUrl,
    batchSize: config.batchSize,
    leaseMs: config.leaseMs,
    pollIntervalMs: config.pollIntervalMs,
  });

  let signalHandler: (() => void) | undefined;
  const shutdownRequested = new Promise<void>((resolveShutdown) => {
    signalHandler = resolveShutdown;
    process.once('SIGTERM', resolveShutdown);
    process.once('SIGINT', resolveShutdown);
  });
  let transportClosed = false;
  const closeTransport = () => {
    if (transportClosed) return;
    transportClosed = true;
    delivery.close();
  };
  const lifecycle = createLifecycleCoordinator({
    timeoutMs: config.shutdownTimeoutMs,
    stopWork: (deadlineMs) => worker.drain(deadlineMs),
    stopAccepting: async () => undefined,
    forceClose: closeTransport,
    closeResources: async (remainingMs) => {
      closeTransport();
      await sql.end({ timeout: Math.max(1, Math.ceil(remainingMs / 1_000)) });
    },
  });
  const running = worker.run();
  let runFailed = false;
  const monitoredRun = running.catch(() => { runFailed = true; });
  await Promise.race([monitoredRun, shutdownRequested]);
  if (signalHandler) {
    process.off('SIGTERM', signalHandler);
    process.off('SIGINT', signalHandler);
  }
  const clean = await lifecycle.shutdown();
  if (runFailed || !clean) process.exitCode = 1;
  await Promise.race([running.catch(() => undefined), new Promise((resolveDone) => setTimeout(resolveDone, 1_000))]);
}

async function main(): Promise<void> {
  try {
    await runOutboxWorker();
  } catch {
    // Startup and database errors are intentionally opaque; never serialize config or SMTP details.
    logProcessEvent('error', 'outbox.worker_start_failed');
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  void main();
}
