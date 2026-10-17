import { describe, expect, it } from 'vitest';
import { compareVersions, parseManifest, parseReleaseResponse, RELEASE_URL_PREFIX } from './release.js';

const goodRelease = {
  tag_name: 'v1.2.3',
  html_url: `${RELEASE_URL_PREFIX}tag/v1.2.3`,
  assets: [
    { name: 'app-release.apk', browser_download_url: 'https://github.com/LucaPisl/simpastil/releases/download/v1.2.3/app-release.apk' },
    { name: 'release-manifest.json', browser_download_url: 'https://github.com/LucaPisl/simpastil/releases/download/v1.2.3/release-manifest.json' },
  ],
};

describe('compareVersions', () => {
  it('compares numerically per part', () => {
    expect(compareVersions('1.0.0', '1.0.1')).toBeLessThan(0);
    expect(compareVersions('1.10.0', '1.9.0')).toBeGreaterThan(0);
    expect(compareVersions('2.0.0', '2.0.0')).toBe(0);
  });
});

describe('parseReleaseResponse', () => {
  it('strips the leading v and returns urls', () => {
    expect(parseReleaseResponse(goodRelease)).toEqual({
      tagVersion: '1.2.3',
      releaseUrl: goodRelease.html_url,
      manifestUrl: goodRelease.assets[1]!.browser_download_url,
    });
  });

  it('accepts objects.githubusercontent.com manifest hosts', () => {
    const body = { ...goodRelease, assets: [{ name: 'release-manifest.json', browser_download_url: 'https://objects.githubusercontent.com/x/y' }] };
    expect(parseReleaseResponse(body)?.manifestUrl).toBe('https://objects.githubusercontent.com/x/y');
  });

  it('returns null without a manifest asset', () => {
    expect(parseReleaseResponse({ ...goodRelease, assets: [goodRelease.assets[0]] })).toBeNull();
    expect(parseReleaseResponse({ ...goodRelease, assets: undefined })).toBeNull();
  });

  it('returns null for a bad tag, foreign hosts or non-objects', () => {
    expect(parseReleaseResponse({ ...goodRelease, tag_name: 'v1.2' })).toBeNull();
    expect(parseReleaseResponse({ ...goodRelease, html_url: 'https://evil.example/releases/tag/v1.2.3' })).toBeNull();
    expect(parseReleaseResponse({
      ...goodRelease,
      assets: [{ name: 'release-manifest.json', browser_download_url: 'https://evil.example/release-manifest.json' }],
    })).toBeNull();
    expect(parseReleaseResponse({
      ...goodRelease,
      assets: [{ name: 'release-manifest.json', browser_download_url: 'http://github.com/x/release-manifest.json' }],
    })).toBeNull();
    expect(parseReleaseResponse(null)).toBeNull();
    expect(parseReleaseResponse('x')).toBeNull();
  });
});

describe('parseManifest', () => {
  it('accepts a digit string or integer build', () => {
    expect(parseManifest({ source: { appBuild: '3', appVersion: '1.0.0' } })).toEqual({ appBuild: 3 });
    expect(parseManifest({ source: { appBuild: 7, appVersion: '1.0.0' } })).toEqual({ appBuild: 7 });
  });

  it('does not require a plain version, so a prerelease suffix still parses', () => {
    expect(parseManifest({ source: { appBuild: '3', appVersion: '1.2.0-rc1' } })).toEqual({ appBuild: 3 });
  });

  it('rejects invalid builds and shapes', () => {
    expect(parseManifest({ source: { appBuild: '0', appVersion: '1.0.0' } })).toBeNull();
    expect(parseManifest({ source: { appBuild: '3a', appVersion: '1.0.0' } })).toBeNull();
    expect(parseManifest({ source: { appBuild: 1.5, appVersion: '1.0.0' } })).toBeNull();
    expect(parseManifest({})).toBeNull();
    expect(parseManifest(null)).toBeNull();
  });
});
