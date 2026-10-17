export interface LatestRelease {
  latestServerVersion: string;
  latestClientBuild: number;
  latestReleaseUrl: string;
}

export const RELEASE_API_URL = 'https://api.github.com/repos/LucaPisl/simpastil/releases/latest';
export const RELEASE_URL_PREFIX = 'https://github.com/LucaPisl/simpastil/releases/';
export const MANIFEST_ASSET_NAME = 'release-manifest.json';
export const VERSION_RE = /^\d+\.\d+\.\d+$/;
const MANIFEST_HOSTS = new Set(['github.com', 'objects.githubusercontent.com']);

export function compareVersions(a: string, b: string): number {
  const left = a.split('.').map(Number);
  const right = b.split('.').map(Number);
  for (let i = 0; i < Math.max(left.length, right.length); i += 1) {
    const diff = (left[i] ?? 0) - (right[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function isValidReleaseUrl(value: unknown): value is string {
  return typeof value === 'string' && value.length <= 256 && !/\s/.test(value) && value.startsWith(RELEASE_URL_PREFIX);
}

function isManifestUrl(value: unknown): value is string {
  if (typeof value !== 'string' || value.length > 2048) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && MANIFEST_HOSTS.has(url.hostname);
  } catch {
    return false;
  }
}

export function parseReleaseResponse(body: unknown): { tagVersion: string; releaseUrl: string; manifestUrl: string } | null {
  if (!isRecord(body)) return null;
  const tag = body.tag_name;
  if (typeof tag !== 'string') return null;
  const tagVersion = tag.startsWith('v') ? tag.slice(1) : tag;
  if (!VERSION_RE.test(tagVersion)) return null;
  if (!isValidReleaseUrl(body.html_url)) return null;
  if (!Array.isArray(body.assets)) return null;
  const asset = body.assets.find((a) => isRecord(a) && a.name === MANIFEST_ASSET_NAME);
  if (!isRecord(asset) || !isManifestUrl(asset.browser_download_url)) return null;
  return { tagVersion, releaseUrl: body.html_url, manifestUrl: asset.browser_download_url };
}

export function parseManifest(body: unknown): { appBuild: number } | null {
  if (!isRecord(body) || !isRecord(body.source)) return null;
  const { appBuild } = body.source;
  let build: number;
  if (typeof appBuild === 'string' && /^\d{1,15}$/.test(appBuild)) build = Number(appBuild);
  else if (typeof appBuild === 'number') build = appBuild;
  else return null;
  if (!Number.isSafeInteger(build) || build <= 0) return null;
  return { appBuild: build };
}
