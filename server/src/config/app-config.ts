import { z } from 'zod';
import { isIP } from 'node:net';
import { readFileSync } from 'node:fs';
import {
  createDeliveryPayloadOpener,
  createDeliveryPayloadSealer,
  type DeliveryPayloadOpener,
  type DeliveryPayloadSealer,
} from '../lib/delivery-payload-crypto.js';
import { createEncryptionCapabilities, type EncryptionCapabilities } from '../lib/crypto.js';

export type RuntimeRole = 'api' | 'test' | 'worker' | 'migrate';
export type ApiRole = 'api' | 'test';

export interface RuntimeEnvironment {
  [name: string]: string | undefined;
}

export interface DatabaseConfig {
  url: string;
  role: 'app_user' | 'outbox_user' | 'migration_owner';
  maxConnections: number;
  superuserUrl?: string;
}

export interface CommonCapabilities {
  canQueryApplicationTables: boolean;
  canRunMigrations: boolean;
  canClaimOutboxJobs: boolean;
}

export interface ApiCapabilities extends CommonCapabilities {
  canUseJwt: true;
  canUseTotp: true;
  canUseApiKeys: true;
  totpCrypto: EncryptionCapabilities;
  apiKeyCrypto: EncryptionCapabilities;
  deliveryPayloadSealer: DeliveryPayloadSealer;
}

export interface OutboxCapabilities extends CommonCapabilities {
  canUseJwt: false;
  canUseTotp: false;
  canUseApiKeys: false;
  deliveryPayloadOpener: DeliveryPayloadOpener;
}

export interface PrivilegedCapabilities extends CommonCapabilities {
  canUseJwt: false;
  canUseTotp: false;
  canUseApiKeys: false;
}

export interface JwtConfig {
  accessTokenTtlSeconds: number;
  privateKey: string;
  publicKey: string;
}

export interface SmtpConfig {
  host: string;
  port: number;
  user?: string;
  password?: string;
  from: string;
}

export interface ApiConfig {
  role: ApiRole;
  nodeEnv: 'development' | 'test' | 'production';
  port: number;
  requestTimeoutMs: number;
  /** Number of reverse-proxy hops in front of the API whose X-Forwarded-For entry is trusted. */
  trustedProxyHops: number;
  /** Ask GitHub once a day whether a newer release exists (UPDATE_CHECK=on|off). */
  updateCheck: boolean;
  shutdownTimeoutMs: number;
  releaseId?: string;
  database: DatabaseConfig;
  capabilities: ApiCapabilities;
  jwt: JwtConfig;
  publicAppUrl?: string;
  /** Compatibility alias for existing route/service consumers. */
  apiBaseUrl?: string;
  corsOrigins: string[] | true;
  admin?: {
    email: string;
    password: string;
  };
}

export interface OutboxConfig {
  role: 'worker';
  nodeEnv: 'development' | 'test' | 'production';
  database: DatabaseConfig;
  capabilities: OutboxCapabilities;
  smtp?: SmtpConfig;
  publicAppUrl?: string;
}

export interface PrivilegedConfig {
  role: 'migrate';
  nodeEnv: 'development' | 'test' | 'production';
  database: DatabaseConfig;
  capabilities: PrivilegedCapabilities;
}

export type AppConfig = ApiConfig | OutboxConfig | PrivilegedConfig;

export class ConfigError extends Error {
  readonly code = 'CONFIG_INVALID';

  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

const RuntimeEnvironmentSchema = z.record(z.string().optional());
const FileBackedNames = [
  'DATABASE_URL', 'DATABASE_URL_OUTBOX', 'DATABASE_URL_SUPER',
  'APP_USER_PASSWORD', 'OUTBOX_USER_PASSWORD',
  'JWT_PRIVATE_KEY', 'JWT_PUBLIC_KEY', 'TOTP_ENC_KEY', 'DELIVERY_PAYLOAD_KEY',
  'SMTP_USER', 'SMTP_PASS',
] as const;

function copyEnvironment(env: RuntimeEnvironment): RuntimeEnvironment {
  const result = RuntimeEnvironmentSchema.safeParse({ ...env });
  if (!result.success) throw new ConfigError('Runtime environment must be a string record');
  return { ...result.data };
}

export function readRuntimeEnvironment(env: RuntimeEnvironment = process.env): RuntimeEnvironment {
  const result = copyEnvironment(env);
  for (const name of FileBackedNames) {
    const path = result[`${name}_FILE`];
    if (!path) continue;
    try {
      result[name] = readFileSync(path, 'utf8').replace(/\r?\n$/, '');
    } catch {
      throw new ConfigError(`${name}_FILE could not be read`);
    }
  }
  return copyEnvironment(result);
}

function required(env: RuntimeEnvironment, name: string, role: RuntimeRole): string {
  const raw = env[name];
  const value = raw?.trim();
  if (!value) throw new ConfigError(`${name} is required for the ${role} role`);
  return value;
}

function requiredSecret(env: RuntimeEnvironment, name: string, role: RuntimeRole): string {
  const value = env[name];
  if (value === undefined || value.length === 0) {
    throw new ConfigError(`${name} is required for the ${role} role`);
  }
  return value;
}

function optionalText(env: RuntimeEnvironment, name: string): string | undefined {
  const raw = env[name];
  if (raw === undefined) return undefined;
  const value = raw.trim();
  if (!value) throw new ConfigError(`${name} must not be blank`);
  return value;
}

function optionalSecret(env: RuntimeEnvironment, name: string): string | undefined {
  const value = env[name];
  if (value === undefined) return undefined;
  if (value.length === 0) throw new ConfigError(`${name} must not be blank`);
  return value;
}

function integer(
  env: RuntimeEnvironment,
  name: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const raw = env[name];
  if (raw === undefined) return fallback;
  const value = raw.trim();
  if (!value || !/^\d+$/.test(value)) {
    throw new ConfigError(`${name} must be an integer from ${min} through ${max}`);
  }
  const numberValue = Number(value);
  if (!Number.isSafeInteger(numberValue) || numberValue < min || numberValue > max) {
    throw new ConfigError(`${name} must be an integer from ${min} through ${max}`);
  }
  return numberValue;
}

function nodeEnv(env: RuntimeEnvironment): ApiConfig['nodeEnv'] {
  const value = env['NODE_ENV']?.trim() || 'development';
  if (value === 'development' || value === 'test' || value === 'production') return value;
  throw new ConfigError('NODE_ENV must be development, test, or production');
}

function databaseRole(role: RuntimeRole): DatabaseConfig['role'] {
  if (role === 'migrate') return 'migration_owner';
  if (role === 'worker') return 'outbox_user';
  return 'app_user';
}

export function loadDatabaseConfig(
  env: RuntimeEnvironment = process.env,
  role: RuntimeRole = 'api',
): DatabaseConfig {
  const maxConnections = role === 'migrate'
    ? 1
    : integer(env, 'POSTGRES_MAX_CONNECTIONS', 10, 1, 100);

  if (role === 'migrate') {
    const superuserUrl = required(env, 'DATABASE_URL_SUPER', role);
    return { url: superuserUrl, role: 'migration_owner', maxConnections, superuserUrl };
  }

  const urlName = role === 'worker' ? 'DATABASE_URL_OUTBOX' : 'DATABASE_URL';
  const url = required(env, urlName, role);
  const expectedUser = role === 'worker' ? 'outbox_user' : 'app_user';
  let parsed: URL;
  try {
    parsed = new URL(url);
    if (!['postgres:', 'postgresql:'].includes(parsed.protocol)
      || decodeURIComponent(parsed.username) !== expectedUser) {
      throw new Error('role mismatch');
    }
  } catch {
    throw new ConfigError(`${urlName} must authenticate as ${expectedUser}`);
  }
  return { url, role: databaseRole(role), maxConnections };
}

function loadHexKey(env: RuntimeEnvironment, name: string, role: RuntimeRole): string {
  const key = requiredSecret(env, name, role);
  if (!/^[0-9a-fA-F]{64}$/.test(key)) {
    throw new ConfigError(`${name} must be exactly 64 hexadecimal characters`);
  }
  return key;
}

export function loadTotpEncryptionKey(env: RuntimeEnvironment = process.env): string {
  return loadHexKey(env, 'TOTP_ENC_KEY', 'api');
}

export function loadOptionalHexKey(
  env: RuntimeEnvironment,
  name: string,
  role: RuntimeRole,
): string | undefined {
  if (env[name] === undefined) return undefined;
  return loadHexKey(env, name, role);
}

function isLoopback(hostname: string): boolean {
  const normalized = hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (normalized === 'localhost' || normalized === '::1') return true;
  if (isIP(normalized) !== 4) return false;
  const octets = normalized.split('.').map(Number);
  return octets.length === 4 && octets[0] === 127 && octets.every((octet) => octet >= 0 && octet <= 255);
}

function loadPublicAppUrl(env: RuntimeEnvironment, environment: ApiConfig['nodeEnv']): string | undefined {
  const explicit = env['PUBLIC_APP_URL'];
  const legacy = environment === 'production' ? undefined : env['API_BASE_URL'];
  const raw = explicit ?? legacy;
  if (raw === undefined) {
    if (environment === 'production') throw new ConfigError('PUBLIC_APP_URL is required in production');
    return undefined;
  }
  const value = raw.trim();
  if (!value) {
    if (environment === 'production') throw new ConfigError('PUBLIC_APP_URL must not be blank');
    return undefined;
  }

  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new ConfigError('PUBLIC_APP_URL must be a valid URL');
  }
  if (parsed.username || parsed.password || !parsed.hostname) {
    throw new ConfigError('PUBLIC_APP_URL must not contain credentials');
  }
  const https = parsed.protocol === 'https:';
  const developmentLoopback = environment === 'development'
    && parsed.protocol === 'http:'
    && isLoopback(parsed.hostname);
  if (!https && !developmentLoopback) {
    throw new ConfigError('PUBLIC_APP_URL must use HTTPS outside development loopback environments');
  }
  return value;
}

function updateCheckFlag(env: RuntimeEnvironment): boolean {
  const value = env.UPDATE_CHECK;
  if (value === undefined || value === 'on') return true;
  if (value === 'off') return false;
  throw new ConfigError('UPDATE_CHECK must be on or off');
}

function loadAdmin(env: RuntimeEnvironment): ApiConfig['admin'] {
  const email = optionalText(env, 'ADMIN_EMAIL');
  const password = optionalSecret(env, 'ADMIN_PASSWORD');
  if (email === undefined && password === undefined) return undefined;
  if (email === undefined || password === undefined) {
    throw new ConfigError('ADMIN_EMAIL and ADMIN_PASSWORD must be configured together');
  }
  return { email, password };
}

function loadSmtp(env: RuntimeEnvironment): SmtpConfig | undefined {
  const host = optionalText(env, 'SMTP_HOST');
  const hasOtherSettings = ['SMTP_PORT', 'SMTP_USER', 'SMTP_PASS', 'SMTP_FROM']
    .some((name) => env[name] !== undefined);
  if (!host) {
    if (hasOtherSettings) throw new ConfigError('SMTP_HOST is required when SMTP settings are configured');
    return undefined;
  }
  const user = optionalSecret(env, 'SMTP_USER');
  const password = optionalSecret(env, 'SMTP_PASS');
  return {
    host,
    port: integer(env, 'SMTP_PORT', 587, 1, 65535),
    ...(user === undefined ? {} : { user }),
    ...(password === undefined ? {} : { password }),
    from: optionalText(env, 'SMTP_FROM') ?? 'noreply@simpastil.local',
  };
}

function baseCapabilities(role: RuntimeRole): CommonCapabilities {
  switch (role) {
    case 'migrate':
      return { canQueryApplicationTables: true, canRunMigrations: true, canClaimOutboxJobs: false };
    case 'worker':
      return { canQueryApplicationTables: false, canRunMigrations: false, canClaimOutboxJobs: true };
    case 'api':
    case 'test':
      return { canQueryApplicationTables: true, canRunMigrations: false, canClaimOutboxJobs: false };
  }
}

export function loadAppConfig(env?: RuntimeEnvironment, role?: 'api' | 'test'): ApiConfig;
export function loadAppConfig(env: RuntimeEnvironment, role: 'worker'): OutboxConfig;
export function loadAppConfig(env: RuntimeEnvironment, role: 'migrate'): PrivilegedConfig;
export function loadAppConfig(
  env: RuntimeEnvironment = process.env,
  role: RuntimeRole = 'api',
): AppConfig {
  const source = copyEnvironment(env);
  const environment = nodeEnv(source);
  const database = loadDatabaseConfig(source, role);

  if (role === 'migrate') {
    return {
      role,
      nodeEnv: environment,
      database,
      capabilities: {
        ...baseCapabilities(role),
        canUseJwt: false,
        canUseTotp: false,
        canUseApiKeys: false,
      },
    };
  }

  if (role === 'worker') {
    const deliveryKey = loadHexKey(source, 'DELIVERY_PAYLOAD_KEY', role);
    const smtp = loadSmtp(source);
    const publicAppUrl = loadPublicAppUrl(source, environment);
    return {
      role,
      nodeEnv: environment,
      database,
      capabilities: {
        ...baseCapabilities(role),
        canUseJwt: false,
        canUseTotp: false,
        canUseApiKeys: false,
        deliveryPayloadOpener: createDeliveryPayloadOpener(deliveryKey),
      },
      ...(smtp ? { smtp } : {}),
      ...(publicAppUrl ? { publicAppUrl } : {}),
    };
  }

  const publicAppUrl = loadPublicAppUrl(source, environment);
  // A blank RELEASE_ID (the Compose default) disables the release-id check.
  const releaseId = source['RELEASE_ID']?.trim() || undefined;
  const privateKey = requiredSecret(source, 'JWT_PRIVATE_KEY', role).replace(/\\n/g, '\n');
  const publicKey = requiredSecret(source, 'JWT_PUBLIC_KEY', role).replace(/\\n/g, '\n');
  const totpKey = loadHexKey(source, 'TOTP_ENC_KEY', role);
  const deliveryKey = loadHexKey(source, 'DELIVERY_PAYLOAD_KEY', role);
  const apiConfig: ApiConfig = {
    role,
    nodeEnv: environment,
    port: integer(source, 'PORT', 3000, 1, 65535),
    requestTimeoutMs: integer(source, 'REQUEST_TIMEOUT_MS', 30_000, 1_000, 120_000),
    trustedProxyHops: integer(source, 'TRUSTED_PROXY_HOPS', 1, 0, 10),
    updateCheck: updateCheckFlag(source),
    shutdownTimeoutMs: integer(source, 'SHUTDOWN_TIMEOUT_MS', 30_000, 1_000, 40_000),
    ...(releaseId ? { releaseId } : {}),
    database,
    capabilities: {
      ...baseCapabilities(role),
      canUseJwt: true,
      canUseTotp: true,
      canUseApiKeys: true,
      totpCrypto: createEncryptionCapabilities(totpKey),
      apiKeyCrypto: createEncryptionCapabilities(totpKey),
      deliveryPayloadSealer: createDeliveryPayloadSealer(deliveryKey),
    },
    jwt: {
      accessTokenTtlSeconds: integer(source, 'JWT_ACCESS_TOKEN_TTL_SECONDS', 900, 60, 3600),
      privateKey,
      publicKey,
    },
    corsOrigins: true,
  };
  if (publicAppUrl) {
    apiConfig.publicAppUrl = publicAppUrl;
    apiConfig.apiBaseUrl = publicAppUrl;
  }
  const cors = source['CORS_ORIGIN'];
  if (cors !== undefined && cors.trim() !== '') {
    const origins = cors.split(',').map((origin) => origin.trim()).filter(Boolean);
    if (origins.length === 0) throw new ConfigError('CORS_ORIGIN must contain at least one origin');
    apiConfig.corsOrigins = origins;
  }
  const admin = loadAdmin(source);
  if (admin) apiConfig.admin = admin;
  return apiConfig;
}
