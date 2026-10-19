import { afterEach, describe, expect, it, vi } from 'vitest';
import { runOutboxWorker } from './index.js';

describe('outbox worker without SMTP', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  it('logs once, opens no database connection and exits cleanly on SIGTERM', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    // The URL is deliberately unreachable: the idle worker must never connect.
    vi.stubEnv('DATABASE_URL_OUTBOX', 'postgres://outbox_user:pw@127.0.0.1:1/none');
    vi.stubEnv('DELIVERY_PAYLOAD_KEY', '1'.repeat(64));
    vi.stubEnv('PUBLIC_APP_URL', 'https://simpastil.example');
    vi.stubEnv('SMTP_HOST', '');
    const log = vi.spyOn(console, 'log').mockImplementation(() => undefined);

    let settled = false;
    const running = runOutboxWorker().then(() => { settled = true; });
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(settled).toBe(false);
    expect(log).toHaveBeenCalledTimes(1);
    expect(JSON.parse(String(log.mock.calls[0]![0]))).toMatchObject({ event: 'outbox.idle_no_smtp' });

    process.emit('SIGTERM');
    await running;
    expect(settled).toBe(true);
    expect(log).toHaveBeenCalledTimes(1);
  });
});
