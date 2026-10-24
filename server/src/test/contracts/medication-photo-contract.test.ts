import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { SyncChangePayloadV2Schema } from '../../modules/sync/sync-payload.js';

const contracts = new URL('../../../../contracts/', import.meta.url);
const readContract = <T>(path: string): T => JSON.parse(readFileSync(new URL(path, contracts), 'utf8')) as T;

interface PhotoFixture {
  cases: Array<{ name: string; expected: { photo: { sha256: string; revision: string } | null }; change: { payload: Record<string, unknown> } }>;
}

describe('medication photo contract', () => {
  const fixture = readContract<PhotoFixture>('fixtures/pill-medication-photo-v1.json');

  it('reads every fixture row through the strict payload schema', () => {
    expect(fixture.cases.map((item) => item.name)).toEqual(['pill-with-photo', 'pill-photo-missing']);
    for (const item of fixture.cases) {
      const parsed = SyncChangePayloadV2Schema.safeParse(item.change);
      expect(parsed.success, item.name + (parsed.success ? '' : JSON.stringify(parsed.error.issues))).toBe(true);
      expect(item.change.payload['photo'] ?? null, item.name).toEqual(item.expected.photo);
    }
  });

  it('refuses a photo reference with a bad hash, an extra key or bytes', () => {
    const base = fixture.cases[0]!.change;
    for (const photo of [
      { sha256: 'xyz', revision: '2' },
      { sha256: 'A'.repeat(64), revision: '2' },
      { sha256: 'a'.repeat(64), revision: '0' },
      { sha256: 'a'.repeat(64), revision: '2', bytes: 'AAAA' },
    ]) {
      const row = { ...base, payload: { ...base.payload, photo } };
      expect(SyncChangePayloadV2Schema.safeParse(row).success).toBe(false);
    }
  });

  it('declares the photo optional in the published contract', () => {
    const schema = readContract<{
      $defs: { pill: { required: string[]; properties: Record<string, unknown> } };
    }>('sync-change-payload-v2.json');
    expect(schema.$defs.pill.properties['photo']).toBeDefined();
    expect(schema.$defs.pill.required).not.toContain('photo');
  });
});
