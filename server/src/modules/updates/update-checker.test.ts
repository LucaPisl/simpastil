import { afterEach, describe, expect, it, vi } from 'vitest';
import { SafeLogger, type SafeLogRecord } from '../../lib/safe-logger.js';
import { UpdateChecker, readServerVersion } from './update-checker.js';
import { RELEASE_URL_PREFIX } from './release.js';

const releaseBody = {
  tag_name: 'v1.2.0',
  html_url: `${RELEASE_URL_PREFIX}tag/v1.2.0`,
  assets: [{ name: 'release-manifest.json', browser_download_url: 'https://github.com/LucaPisl/simpastil/releases/download/v1.2.0/release-manifest.json' }],
};
const manifestBody = { source: { appBuild: '5', appVersion: '1.2.0' } };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

function setup(responses: Array<() => Response | Promise<Response>>, currentServerVersion = '1.0.0') {
  const records: SafeLogRecord[] = [];
  const logger = new SafeLogger({
    info: (r) => records.push(r),
    warn: (r) => records.push(r),
    error: (r) => records.push(r),
  });
  const queue = [...responses];
  const fetchMock = vi.fn(async () => {
    const next = queue.shift();
    if (!next) throw new Error('unexpected fetch');
    return next();
  });
  const checker = new UpdateChecker({ currentServerVersion, fetch: fetchMock as unknown as typeof fetch, logger });
  return { checker, records, fetchMock };
}

afterEach(() => vi.useRealTimers());

describe('UpdateChecker', () => {
  it('stores a newer release and logs update.available once', async () => {
    const { checker, records, fetchMock } = setup([() => json(releaseBody), () => json(manifestBody)]);
    await checker.checkOnce();
    expect(checker.current()).toEqual({
      latestServerVersion: '1.2.0',
      latestClientBuild: 5,
      latestReleaseUrl: releaseBody.html_url,
    });
    expect(records).toEqual([{
      event: 'update.available',
      currentServerVersion: '1.0.0',
      latestServerVersion: '1.2.0',
      latestClientBuild: 5,
      releaseUrl: releaseBody.html_url,
    }]);
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect((init.headers as Record<string, string>)['User-Agent']).toMatch(/^simpastil-server\/1\.0\.0$/);
  });

  it('stores but does not announce an equal or older release', async () => {
    for (const current of ['1.2.0', '1.3.0']) {
      const { checker, records } = setup([() => json(releaseBody), () => json(manifestBody)], current);
      await checker.checkOnce();
      expect(checker.current()?.latestServerVersion).toBe('1.2.0');
      expect(records).toEqual([]);
    }
  });

  it.each([
    ['network error', [() => { throw new Error('boom'); }], 'UPDATE_CHECK_NETWORK'],
    ['404', [() => json({}, 404)], 'UPDATE_CHECK_STATUS'],
    ['invalid json', [() => new Response('<html>', { status: 200 })], 'UPDATE_CHECK_INVALID'],
    ['missing manifest asset', [() => json({ ...releaseBody, assets: [] })], 'UPDATE_CHECK_INVALID'],
    ['invalid manifest', [() => json(releaseBody), () => json({ source: { appBuild: '0' } })], 'UPDATE_CHECK_INVALID'],
    ['manifest 500', [() => json(releaseBody), () => json({}, 500)], 'UPDATE_CHECK_STATUS'],
  ] as const)('keeps the previous result on %s', async (_name, responses, code) => {
    const { checker, records } = setup([() => json(releaseBody), () => json(manifestBody), ...responses]);
    await checker.checkOnce();
    const previous = checker.current();
    records.length = 0;
    await expect(checker.checkOnce()).resolves.toBeUndefined();
    expect(checker.current()).toEqual(previous);
    expect(records).toEqual([{ event: 'update.check_failed', errorCode: code }]);
  });

  it('rejects an oversize body and a foreign final host, keeping the previous result', async () => {
    const big = 'x'.repeat(1_048_577);
    const foreign = () => {
      const r = json(releaseBody);
      Object.defineProperty(r, 'url', { value: 'https://evil.example/latest' });
      return r;
    };
    const declared = () => new Response('{}', { status: 200, headers: { 'content-length': '2000000' } });
    for (const bad of [() => new Response(big, { status: 200 }), declared, foreign]) {
      const { checker, records } = setup([() => json(releaseBody), () => json(manifestBody), bad]);
      await checker.checkOnce();
      const previous = checker.current();
      records.length = 0;
      await checker.checkOnce();
      expect(checker.current()).toEqual(previous);
      expect(records).toEqual([{ event: 'update.check_failed', errorCode: 'UPDATE_CHECK_INVALID' }]);
    }
  });

  it('start() schedules a first check and an interval, stop() clears them', async () => {
    vi.useFakeTimers();
    const { checker, fetchMock } = setup([() => json(releaseBody), () => json(manifestBody)]);
    const handle = checker.start(1_000, 10_000);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    handle.stop();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe('readServerVersion', () => {
  it('reads a semver from package.json', () => {
    expect(readServerVersion()).toMatch(/^\d+\.\d+\.\d+$/);
  });
});
