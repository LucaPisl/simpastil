import { readFileSync } from 'node:fs';
import type { SafeLogger } from '../../lib/safe-logger.js';
import {
  compareVersions,
  parseManifest,
  parseReleaseResponse,
  RELEASE_API_URL,
  VERSION_RE,
  type LatestRelease,
} from './release.js';

const REQUEST_TIMEOUT_MS = 10_000;
const DAY_MS = 24 * 60 * 60 * 1_000;
const FIRST_CHECK_DELAY_MS = 60_000;
const MAX_BODY_BYTES = 1_048_576;
// The API, the release page host, and the CDNs GitHub redirects asset downloads to.
const ALLOWED_FINAL_HOSTS = new Set([
  'api.github.com',
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
]);

function finalHostAllowed(response: Response): boolean {
  if (!response.url) return true;
  try {
    const url = new URL(response.url);
    return url.protocol === 'https:' && ALLOWED_FINAL_HOSTS.has(url.hostname);
  } catch {
    return false;
  }
}

async function readCapped(response: Response): Promise<string> {
  const declared = Number(response.headers.get('content-length'));
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) throw new CheckFailure('UPDATE_CHECK_INVALID');
  if (!response.body) return '';
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel().catch(() => undefined);
      throw new CheckFailure('UPDATE_CHECK_INVALID');
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString('utf8');
}

class CheckFailure extends Error {
  constructor(readonly code: 'UPDATE_CHECK_NETWORK' | 'UPDATE_CHECK_STATUS' | 'UPDATE_CHECK_INVALID') {
    super(code);
  }
}

export function readServerVersion(): string {
  let version: unknown;
  try {
    const raw = readFileSync(new URL('../../../package.json', import.meta.url), 'utf8');
    version = (JSON.parse(raw) as { version?: unknown }).version;
  } catch {
    throw new Error('Server package.json could not be read');
  }
  if (typeof version !== 'string' || !VERSION_RE.test(version)) {
    throw new Error('Server package.json version is not a semantic version');
  }
  return version;
}

export interface UpdateCheckerOptions {
  currentServerVersion: string;
  fetch?: typeof fetch;
  logger: SafeLogger;
  now?: () => number;
}

export class UpdateChecker {
  private latest: LatestRelease | undefined;
  private readonly fetchFn: typeof fetch;

  constructor(private readonly opts: UpdateCheckerOptions) {
    this.fetchFn = opts.fetch ?? fetch;
  }

  current(): LatestRelease | undefined {
    return this.latest;
  }

  async checkOnce(): Promise<void> {
    try {
      const release = await this.fetchLatest();
      this.latest = release;
      if (compareVersions(release.latestServerVersion, this.opts.currentServerVersion) > 0) {
        this.opts.logger.info('update.available', {
          currentServerVersion: this.opts.currentServerVersion,
          latestServerVersion: release.latestServerVersion,
          latestClientBuild: release.latestClientBuild,
          releaseUrl: release.latestReleaseUrl,
        });
      }
    } catch (error) {
      const errorCode = error instanceof CheckFailure ? error.code : 'UPDATE_CHECK_NETWORK';
      this.opts.logger.warn('update.check_failed', { errorCode });
    }
  }

  start(firstDelayMs = FIRST_CHECK_DELAY_MS, intervalMs = DAY_MS): { stop(): void } {
    let interval: NodeJS.Timeout | undefined;
    const first = setTimeout(() => {
      void this.checkOnce();
      interval = setInterval(() => void this.checkOnce(), intervalMs);
      interval.unref();
    }, firstDelayMs);
    first.unref();
    return {
      stop: () => {
        clearTimeout(first);
        if (interval) clearInterval(interval);
      },
    };
  }

  private async getJson(url: string): Promise<unknown> {
    let response: Response;
    try {
      response = await this.fetchFn(url, {
        headers: {
          Accept: 'application/vnd.github+json',
          'User-Agent': `simpastil-server/${this.opts.currentServerVersion}`,
        },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        redirect: 'follow',
      });
    } catch {
      throw new CheckFailure('UPDATE_CHECK_NETWORK');
    }
    if (!response.ok) throw new CheckFailure('UPDATE_CHECK_STATUS');
    if (!finalHostAllowed(response)) throw new CheckFailure('UPDATE_CHECK_INVALID');
    try {
      return JSON.parse(await readCapped(response)) as unknown;
    } catch (error) {
      if (error instanceof CheckFailure) throw error;
      throw new CheckFailure('UPDATE_CHECK_INVALID');
    }
  }

  private async fetchLatest(): Promise<LatestRelease> {
    const release = parseReleaseResponse(await this.getJson(RELEASE_API_URL));
    if (!release) throw new CheckFailure('UPDATE_CHECK_INVALID');
    const manifest = parseManifest(await this.getJson(release.manifestUrl));
    if (!manifest) throw new CheckFailure('UPDATE_CHECK_INVALID');
    return {
      latestServerVersion: release.tagVersion,
      latestClientBuild: manifest.appBuild,
      latestReleaseUrl: release.releaseUrl,
    };
  }
}
