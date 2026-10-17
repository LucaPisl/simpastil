import { loadAppConfig, type ApiConfig, type RuntimeEnvironment } from '../../config/app-config.js';

export interface TestConfigOverrides {
  privateKey: string;
  publicKey: string;
  adminCredentials?: { email: string; password: string };
}

export function buildTestConfig(overrides: TestConfigOverrides): ApiConfig {
  const env: RuntimeEnvironment = {
    NODE_ENV: 'test',
    DATABASE_URL: process.env['TEST_DATABASE_URL_APP']
      ?? process.env['TEST_DATABASE_URL']
      ?? process.env['DATABASE_URL_APP']
      ?? process.env['DATABASE_URL'],
    JWT_PRIVATE_KEY: overrides.privateKey,
    JWT_PUBLIC_KEY: overrides.publicKey,
    TOTP_ENC_KEY: '0'.repeat(64),
    DELIVERY_PAYLOAD_KEY: '1'.repeat(64),
    ...(overrides.adminCredentials
      ? {
          ADMIN_EMAIL: overrides.adminCredentials.email,
          ADMIN_PASSWORD: overrides.adminCredentials.password,
        }
      : {}),
  };
  return loadAppConfig(env, 'test');
}
