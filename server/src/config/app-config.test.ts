import { describe, expect, it } from 'vitest';
import {
  ConfigError,
  loadAppConfig,
  loadOptionalHexKey,
  type RuntimeEnvironment,
} from './app-config.js';

const baseEnv: RuntimeEnvironment = {
  NODE_ENV: 'test',
  DATABASE_URL: 'postgresql://app_user:testpass@127.0.0.1:5432/simpastil',
  DATABASE_URL_OUTBOX: 'postgresql://outbox_user:testpass@127.0.0.1:5432/simpastil',
  DATABASE_URL_SUPER: 'postgresql://postgres:supersecret@127.0.0.1:5432/simpastil',
  JWT_PRIVATE_KEY: 'private-key',
  JWT_PUBLIC_KEY: 'public-key',
  TOTP_ENC_KEY: 'a'.repeat(64),
  DELIVERY_PAYLOAD_KEY: 'b'.repeat(64),
  PUBLIC_APP_URL: 'https://app.example.test',
  CORS_ORIGIN: 'https://app.example.test, https://admin.example.test',
  POSTGRES_MAX_CONNECTIONS: '10',
};

describe('validated runtime configuration', () => {
  it('trusts exactly one proxy hop by default and accepts an explicit hop count', () => {
    const api = (extra: RuntimeEnvironment = {}) => {
      const config = loadAppConfig({ ...baseEnv, ...extra }, 'api');
      if (config.role !== 'api') throw new Error('expected api config');
      return config;
    };
    expect(api().trustedProxyHops).toBe(1);
    expect(api({ TRUSTED_PROXY_HOPS: '2' }).trustedProxyHops).toBe(2);
    expect(api({ TRUSTED_PROXY_HOPS: '0' }).trustedProxyHops).toBe(0);
    expect(() => api({ TRUSTED_PROXY_HOPS: 'many' })).toThrow(/TRUSTED_PROXY_HOPS/);
  });

  it('enables the update check by default and accepts on or off only', () => {
    const api = (extra: RuntimeEnvironment = {}) => {
      const config = loadAppConfig({ ...baseEnv, ...extra }, 'api');
      if (config.role !== 'api') throw new Error('expected api config');
      return config;
    };
    expect(api().updateCheck).toBe(true);
    expect(api({ UPDATE_CHECK: 'on' }).updateCheck).toBe(true);
    expect(api({ UPDATE_CHECK: 'off' }).updateCheck).toBe(false);
    expect(() => api({ UPDATE_CHECK: 'maybe' })).toThrow(/UPDATE_CHECK/);
  });

  it('builds an API config with only least-privilege application capabilities', () => {
    const config = loadAppConfig(baseEnv, 'api');

    expect(config.role).toBe('api');
    expect(config.database).toEqual({
      url: baseEnv.DATABASE_URL,
      role: 'app_user',
      maxConnections: 10,
    });
    expect(config.database.superuserUrl).toBeUndefined();
    expect(config.capabilities).toEqual(expect.objectContaining({
      canQueryApplicationTables: true,
      canRunMigrations: false,
      canClaimOutboxJobs: false,
      canUseJwt: true,
      canUseTotp: true,
      canUseApiKeys: true,
    }));
    expect(config.capabilities).toHaveProperty('deliveryPayloadSealer');
    expect(config.capabilities).not.toHaveProperty('deliveryPayloadOpener');
    expect(config.jwt.accessTokenTtlSeconds).toBe(900);
    expect(config.corsOrigins).toEqual([
      'https://app.example.test',
      'https://admin.example.test',
    ]);
  });

  it('keeps migration and outbox capabilities in separate typed roles', () => {
    const migrate = loadAppConfig(baseEnv, 'migrate');
    const worker = loadAppConfig(baseEnv, 'worker');
    const sealed = loadAppConfig(baseEnv, 'api').capabilities.deliveryPayloadSealer.seal('fixture');

    expect(migrate).toEqual(expect.objectContaining({
      role: 'migrate',
      database: {
        url: baseEnv.DATABASE_URL_SUPER,
        role: 'migration_owner',
        maxConnections: 1,
        superuserUrl: baseEnv.DATABASE_URL_SUPER,
      },
    }));
    expect(migrate.capabilities).toEqual(expect.objectContaining({
      canQueryApplicationTables: true,
      canRunMigrations: true,
      canClaimOutboxJobs: false,
      canUseJwt: false,
      canUseTotp: false,
      canUseApiKeys: false,
    }));
    expect(worker).toEqual(expect.objectContaining({
      role: 'worker',
      database: {
        url: baseEnv.DATABASE_URL_OUTBOX,
        role: 'outbox_user',
        maxConnections: 10,
      },
    }));
    expect(worker.capabilities).toEqual(expect.objectContaining({
      canQueryApplicationTables: false,
      canRunMigrations: false,
      canClaimOutboxJobs: true,
      canUseJwt: false,
      canUseTotp: false,
      canUseApiKeys: false,
    }));
    expect(worker.capabilities).toHaveProperty('deliveryPayloadOpener');
    expect(worker.capabilities).not.toHaveProperty('deliveryPayloadSealer');
    expect(worker.capabilities.deliveryPayloadOpener.open(sealed)).toBe('fixture');
  });

  it('enforces TTL absence/default, bounds, integer syntax, and blank rejection', () => {
    expect(loadAppConfig({ ...baseEnv, JWT_ACCESS_TOKEN_TTL_SECONDS: undefined }, 'api').jwt.accessTokenTtlSeconds).toBe(900);
    expect(loadAppConfig({ ...baseEnv, JWT_ACCESS_TOKEN_TTL_SECONDS: '60' }, 'api').jwt.accessTokenTtlSeconds).toBe(60);
    expect(loadAppConfig({ ...baseEnv, JWT_ACCESS_TOKEN_TTL_SECONDS: '3600' }, 'api').jwt.accessTokenTtlSeconds).toBe(3600);
    for (const value of ['59', '3601', '1.5', 'abc', '']) {
      expect(() => loadAppConfig({ ...baseEnv, JWT_ACCESS_TOKEN_TTL_SECONDS: value }, 'api'))
        .toThrowError(new ConfigError('JWT_ACCESS_TOKEN_TTL_SECONDS must be an integer from 60 through 3600'));
    }
  });

  it('treats a blank RELEASE_ID (the Compose default) as no release pin', () => {
    expect(loadAppConfig({ ...baseEnv, RELEASE_ID: '' }, 'api').releaseId).toBeUndefined();
    expect(loadAppConfig({ ...baseEnv, RELEASE_ID: '  ' }, 'api').releaseId).toBeUndefined();
    expect(loadAppConfig({ ...baseEnv, RELEASE_ID: 'migration-0019' }, 'api').releaseId).toBe('migration-0019');
  });

  it('requires HTTPS in production and allows HTTP only for development loopback', () => {
    expect(() => loadAppConfig({ ...baseEnv, NODE_ENV: 'production' }, 'api')).not.toThrow();
    expect(() => loadAppConfig({ ...baseEnv, NODE_ENV: 'production', PUBLIC_APP_URL: 'http://app.example.test' }, 'api'))
      .toThrowError(new ConfigError('PUBLIC_APP_URL must use HTTPS outside development loopback environments'));
    expect(() => loadAppConfig({ ...baseEnv, NODE_ENV: 'production', PUBLIC_APP_URL: undefined }, 'api'))
      .toThrowError(new ConfigError('PUBLIC_APP_URL is required in production'));
    expect(loadAppConfig({ ...baseEnv, NODE_ENV: 'development', PUBLIC_APP_URL: 'http://127.0.0.1:3000' }, 'api').publicAppUrl)
      .toBe('http://127.0.0.1:3000');
    expect(() => loadAppConfig({ ...baseEnv, NODE_ENV: 'development', PUBLIC_APP_URL: 'http://app.example.test' }, 'api'))
      .toThrowError(new ConfigError('PUBLIC_APP_URL must use HTTPS outside development loopback environments'));
    expect(() => loadAppConfig({ ...baseEnv, NODE_ENV: 'development', PUBLIC_APP_URL: 'http://127.attacker.example' }, 'api'))
      .toThrowError(new ConfigError('PUBLIC_APP_URL must use HTTPS outside development loopback environments'));
  });

  it('preserves secret bytes instead of trimming configured passwords', () => {
    const api = loadAppConfig({ ...baseEnv, ADMIN_EMAIL: 'admin@example.test', ADMIN_PASSWORD: ' pass with spaces ' }, 'api');
    const worker = loadAppConfig({ ...baseEnv, SMTP_HOST: 'smtp.example.test', SMTP_PASS: ' smtp secret ' }, 'worker');
    expect(api.admin?.password).toBe(' pass with spaces ');
    expect(worker.smtp?.password).toBe(' smtp secret ');
  });

  it('derives smtpConfigured from a non-blank SMTP_HOST only', () => {
    expect(loadAppConfig(baseEnv, 'api').smtpConfigured).toBe(false);
    expect(loadAppConfig({ ...baseEnv, SMTP_HOST: '' }, 'api').smtpConfigured).toBe(false);
    expect(loadAppConfig({ ...baseEnv, SMTP_HOST: '   ' }, 'api').smtpConfigured).toBe(false);
    expect(loadAppConfig({ ...baseEnv, SMTP_HOST: 'smtp.example.test' }, 'api').smtpConfigured).toBe(true);
    // A blank host disables SMTP for the worker too, whatever else is set.
    expect(loadAppConfig({ ...baseEnv, SMTP_HOST: '', SMTP_PORT: '2525' }, 'worker').smtp).toBeUndefined();
  });

  it('validates optional key rotation through the same boundary', () => {
    expect(loadOptionalHexKey(baseEnv, 'TOTP_ENC_KEY_OLD', 'migrate')).toBeUndefined();
    expect(loadOptionalHexKey({ ...baseEnv, TOTP_ENC_KEY_OLD: 'c'.repeat(64) }, 'TOTP_ENC_KEY_OLD', 'migrate'))
      .toBe('c'.repeat(64));
    expect(() => loadOptionalHexKey({ ...baseEnv, TOTP_ENC_KEY_OLD: 'not-hex' }, 'TOTP_ENC_KEY_OLD', 'migrate'))
      .toThrowError(new ConfigError('TOTP_ENC_KEY_OLD must be exactly 64 hexadecimal characters'));
  });

  it('does not mutate the supplied environment map while normalizing values', () => {
    const env = { ...baseEnv };
    loadAppConfig(env, 'api');
    expect(env).toEqual(baseEnv);
  });
});
