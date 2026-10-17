import { describe, expect, it } from 'vitest';
import { buildApp } from '../../app.js';
import { loadAppConfig } from '../../config/app-config.js';
import type { Db } from '../../db/client.js';
import { buildPasswordResetUrl } from '../../modules/auth/auth.service.js';
import { createDeliverySubmitter } from '../../lib/delivery.js';
import { generateTestKeyPair } from '../helpers/key-helpers.js';

describe('sanitized test environment boundary', () => {
  it('does not inherit the repository .env canary', () => {
    expect(process.env['SIMPASTIL_REPOSITORY_ENV_CANARY']).toBeUndefined();
    expect(process.env['SIMPASTIL_UNSAFE_CANARY']).toBeUndefined();
  });

  it('constructs a test config from the explicit allowlist only', () => {
    const config = loadAppConfig({
      NODE_ENV: 'test',
      DATABASE_URL: process.env['TEST_DATABASE_URL'] ?? 'postgresql://app_user:testpass@127.0.0.1:5432/simpastil',
      JWT_PRIVATE_KEY: 'private-key',
      JWT_PUBLIC_KEY: 'public-key',
      TOTP_ENC_KEY: 'a'.repeat(64),
      DELIVERY_PAYLOAD_KEY: 'b'.repeat(64),
    }, 'test');

    expect(config.role).toBe('test');
    expect(config.database.role).toBe('app_user');
    expect(config.database.superuserUrl).toBeUndefined();
    expect(config.capabilities.canRunMigrations).toBe(false);
    expect(process.env['DATABASE_URL']).toBe(
      process.env['TEST_DATABASE_URL'] ?? process.env['TEST_DATABASE_URL_APP'],
    );
    expect(process.env['ADMIN_PASSWORD']).toBeUndefined();
    expect(process.env['SMTP_PASS']).toBeUndefined();
    expect(process.env['SIMPASTIL_LIVE_SECRET']).toBeUndefined();
  });

  it('preserves body-less DELETE compatibility while building without ambient DB state', async () => {
    const keys = generateTestKeyPair();
    const config = loadAppConfig({
      NODE_ENV: 'test',
      DATABASE_URL: process.env['TEST_DATABASE_URL'] ?? 'postgresql://app_user:testpass@127.0.0.1:5432/simpastil',
      JWT_PRIVATE_KEY: keys.privateKey,
      JWT_PUBLIC_KEY: keys.publicKey,
      TOTP_ENC_KEY: 'a'.repeat(64),
      DELIVERY_PAYLOAD_KEY: 'b'.repeat(64),
    }, 'test');
    const app = await buildApp(config, {
      db: {} as Db,
      encryption: config.capabilities.totpCrypto,
      deliveryPayloadSealer: config.capabilities.deliveryPayloadSealer,
      deliverySubmitter: { submit: async () => {} },
    }, { logger: false });
    try {
      const response = await app.inject({
        method: 'DELETE',
        url: '/api/v1/profiles/00000000-0000-0000-0000-000000000000',
        headers: { 'content-type': 'application/json' },
      });
      expect(response.statusCode).toBe(401);
    } finally {
      await app.close();
    }
  });

  it('builds reset links from the validated URL without duplicating its scheme', () => {
    expect(buildPasswordResetUrl('https://app.example.test', 'token')).toBe(
      'https://app.example.test/#/reset-password?token=token',
    );
    expect(buildPasswordResetUrl('http://127.0.0.1:3000/', 'token')).toBe(
      'http://127.0.0.1:3000/#/reset-password?token=token',
    );
  });

  it('seals delivery payloads before handing them to the injected sink', async () => {
    const envelopes: Array<{ kind: 'password-reset' | 'invite'; recipient: string; ciphertext: string }> = [];
    const submitter = createDeliverySubmitter(
      (payload) => `sealed:${payload}`,
      { enqueue: async (envelope) => { envelopes.push(envelope); } },
    );
    await submitter.submit({ kind: 'password-reset', recipient: 'user@example.test', payload: 'opaque body' });
    expect(envelopes).toEqual([{
      kind: 'password-reset',
      recipient: 'user@example.test',
      ciphertext: 'sealed:opaque body',
    }]);
  });
});
