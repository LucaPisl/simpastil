import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { loadOutboxWorkerConfig } from './worker-config.js';

describe('outbox worker SMTP credential files', () => {
  let directory: string;

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), 'worker-config-'));
  });

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true });
  });

  function environment(extra: Record<string, string>): Record<string, string> {
    return {
      NODE_ENV: 'production',
      DATABASE_URL_OUTBOX: 'postgres://outbox_user:pw@postgres:5432/simpastil',
      DELIVERY_PAYLOAD_KEY: '1'.repeat(64),
      PUBLIC_APP_URL: 'https://simpastil.example',
      SMTP_HOST: 'smtp.example.test',
      ...extra,
    };
  }

  it('treats empty credential files as unauthenticated SMTP', () => {
    const empty = join(directory, 'empty');
    writeFileSync(empty, '');
    const config = loadOutboxWorkerConfig(environment({ SMTP_USER_FILE: empty, SMTP_PASS_FILE: empty }));
    expect(config.smtp.user).toBeUndefined();
    expect(config.smtp.password).toBeUndefined();
  });

  it('still reads populated credential files', () => {
    const user = join(directory, 'user');
    const pass = join(directory, 'pass');
    writeFileSync(user, 'mailer\n');
    writeFileSync(pass, 'secret\n');
    const config = loadOutboxWorkerConfig(environment({ SMTP_USER_FILE: user, SMTP_PASS_FILE: pass }));
    expect(config.smtp).toMatchObject({ user: 'mailer', password: 'secret' });
  });
});
