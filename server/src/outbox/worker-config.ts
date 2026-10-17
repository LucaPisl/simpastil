import { isIP } from 'node:net';
import { readFileSync } from 'node:fs';
import {
  createDeliveryPayloadOpener,
  type DeliveryPayloadOpener,
} from '../lib/delivery-payload-crypto.js';

export interface WorkerSmtpConfig {
  host: string;
  port: number;
  user?: string;
  password?: string;
  from: string;
}

export interface OutboxWorkerConfig {
  databaseUrl: string;
  maxConnections: number;
  nodeEnv: 'development' | 'test' | 'production';
  publicAppUrl: string;
  smtp: WorkerSmtpConfig;
  payloadOpener: DeliveryPayloadOpener;
  batchSize: number;
  leaseMs: number;
  pollIntervalMs: number;
  shutdownTimeoutMs: number;
}

export class WorkerConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WorkerConfigError';
  }
}

type Environment = Record<string, string | undefined>;

function text(env: Environment, name: string, fallback?: string): string {
  const value = env[name]?.trim() ?? fallback;
  if (!value) throw new WorkerConfigError(`${name} is required for the outbox worker`);
  return value;
}

function integer(env: Environment, name: string, fallback: number, min: number, max: number): number {
  const raw = env[name];
  if (raw === undefined) return fallback;
  const value = raw.trim();
  if (!/^\d+$/.test(value)) throw new WorkerConfigError(`${name} is outside its allowed range`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    throw new WorkerConfigError(`${name} is outside its allowed range`);
  }
  return parsed;
}

function nodeEnvironment(env: Environment): OutboxWorkerConfig['nodeEnv'] {
  const value = env['NODE_ENV']?.trim() || 'development';
  if (value === 'development' || value === 'test' || value === 'production') return value;
  throw new WorkerConfigError('NODE_ENV must be development, test, or production');
}

function validateDatabaseUrl(value: string): string {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new WorkerConfigError('DATABASE_URL_OUTBOX must be a valid PostgreSQL URL');
  }
  if (!['postgres:', 'postgresql:'].includes(parsed.protocol)
    || decodeURIComponent(parsed.username) !== 'outbox_user') {
    throw new WorkerConfigError('DATABASE_URL_OUTBOX must authenticate as outbox_user');
  }
  return value;
}

function isLoopback(hostname: string): boolean {
  const normalized = hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (normalized === 'localhost' || normalized === '::1') return true;
  return isIP(normalized) === 4 && normalized.split('.')[0] === '127';
}

function publicAppUrl(env: Environment, nodeEnv: OutboxWorkerConfig['nodeEnv']): string {
  const configured = env['PUBLIC_APP_URL']
    ?? (nodeEnv === 'production' ? undefined : env['API_BASE_URL']);
  const raw = configured?.trim();
  if (configured !== undefined && !raw) {
    throw new WorkerConfigError('PUBLIC_APP_URL must not be blank');
  }
  if (!raw && nodeEnv === 'production') {
    throw new WorkerConfigError('PUBLIC_APP_URL is required in production');
  }
  const value = raw || 'http://127.0.0.1:3000';
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new WorkerConfigError('PUBLIC_APP_URL must be a valid URL');
  }
  if (!parsed.hostname || parsed.username || parsed.password) {
    throw new WorkerConfigError('PUBLIC_APP_URL must not contain credentials');
  }
  const isDevelopmentLoopback = nodeEnv === 'development'
    && parsed.protocol === 'http:'
    && isLoopback(parsed.hostname);
  if (parsed.protocol !== 'https:' && !isDevelopmentLoopback) {
    throw new WorkerConfigError('PUBLIC_APP_URL must use HTTPS outside development loopback environments');
  }
  return value;
}

function smtpConfig(env: Environment): WorkerSmtpConfig {
  const host = text(env, 'SMTP_HOST');
  const port = integer(env, 'SMTP_PORT', 587, 1, 65535);
  const user = env['SMTP_USER']?.trim();
  const password = env['SMTP_PASS'];
  if (user !== undefined && !user) throw new WorkerConfigError('SMTP_USER must not be blank');
  if ((user === undefined) !== (password === undefined)) {
    throw new WorkerConfigError('SMTP_USER and SMTP_PASS must be configured together');
  }
  if (password !== undefined && password.length === 0) {
    throw new WorkerConfigError('SMTP_PASS must not be blank');
  }
  const from = text(env, 'SMTP_FROM', 'noreply@simpastil.local');
  return {
    host,
    port,
    ...(user === undefined ? {} : { user }),
    ...(password === undefined ? {} : { password }),
    from,
  };
}

export function loadOutboxWorkerConfig(env: Environment = process.env): OutboxWorkerConfig {
  const source = { ...env };
  for (const name of ['DATABASE_URL_OUTBOX', 'DELIVERY_PAYLOAD_KEY', 'SMTP_USER', 'SMTP_PASS']) {
    const path = source[`${name}_FILE`];
    if (!path) continue;
    try {
      const value = readFileSync(path, 'utf8').replace(/\r?\n$/, '');
      // An empty SMTP credential file (Compose mounts /dev/null when the path is
      // unset) means "no SMTP authentication", not a blank credential.
      if (value === '' && (name === 'SMTP_USER' || name === 'SMTP_PASS')) {
        delete source[name];
      } else {
        source[name] = value;
      }
    } catch {
      throw new WorkerConfigError(`${name}_FILE could not be read`);
    }
  }
  const nodeEnv = nodeEnvironment(source);
  const deliveryKey = text(source, 'DELIVERY_PAYLOAD_KEY');
  if (!/^[0-9a-fA-F]{64}$/.test(deliveryKey)) {
    throw new WorkerConfigError('DELIVERY_PAYLOAD_KEY must be exactly 64 hexadecimal characters');
  }
  return {
    databaseUrl: validateDatabaseUrl(text(source, 'DATABASE_URL_OUTBOX')),
    maxConnections: integer(source, 'POSTGRES_MAX_CONNECTIONS', 2, 1, 20),
    nodeEnv,
    publicAppUrl: publicAppUrl(source, nodeEnv),
    smtp: smtpConfig(source),
    payloadOpener: createDeliveryPayloadOpener(deliveryKey),
    batchSize: integer(source, 'OUTBOX_BATCH_SIZE', 10, 1, 100),
    leaseMs: integer(source, 'OUTBOX_LEASE_MS', 60_000, 60_000, 300_000),
    pollIntervalMs: integer(source, 'OUTBOX_POLL_INTERVAL_MS', 2_000, 100, 60_000),
    shutdownTimeoutMs: integer(source, 'OUTBOX_SHUTDOWN_TIMEOUT_MS', 10_000, 1_000, 40_000),
  };
}
