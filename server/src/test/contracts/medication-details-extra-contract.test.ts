import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { CreatePillSchema, UpdatePillSchema } from '../../modules/pills/pills.schema.js';
import { MEDICATION_DETAILS_EXTRA_KEYS } from '../../modules/shared/medication-details-extra.js';
import { detailsExtraPayload } from '../../modules/sync/sync-change-writer.js';
import { SyncChangePayloadV2Schema } from '../../modules/sync/sync-payload.js';

const contracts = new URL('../../../../contracts/', import.meta.url);
const readContract = <T>(path: string): T => JSON.parse(readFileSync(new URL(path, contracts), 'utf8')) as T;

interface ExtraFixture {
  keys: string[];
  cases: Array<{ name: string; expected: Record<string, unknown>; change: { payload: Record<string, unknown> } }>;
}

const base = { mutationId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301', name: 'Paracetamol' };
const update = { mutationId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301', baseRevision: '1' };

describe('medication details extra contract', () => {
  const fixture = readContract<ExtraFixture>('fixtures/pill-medication-details-extra-v1.json');

  it('keeps the fixture key list in step with the server', () => {
    expect(fixture.keys).toEqual([...MEDICATION_DETAILS_EXTRA_KEYS]);
  });

  it('reads every fixture row through the strict payload schema, with and without the keys', () => {
    expect(fixture.cases.map((item) => item.name)).toEqual(expect.arrayContaining([
      'pill-all-extras', 'pill-limits-only', 'pill-extras-missing', 'pill-extras-null',
    ]));
    for (const item of fixture.cases) {
      const parsed = SyncChangePayloadV2Schema.safeParse(item.change);
      expect(parsed.success, item.name + (parsed.success ? '' : JSON.stringify(parsed.error.issues))).toBe(true);
      // The writer emits exactly the keys that are set, no more.
      const written = detailsExtraPayload(item.change.payload);
      const set = Object.entries(item.expected).filter(([, value]) => value !== null);
      expect(Object.keys(written).sort(), item.name).toEqual(set.map(([key]) => key).sort());
    }
  });

  it('declares every key optional in the published contract', () => {
    const schema = readContract<{
      $defs: { pill: { required: string[]; properties: Record<string, unknown> } };
    }>('sync-change-payload-v2.json');
    for (const key of fixture.keys) {
      expect(schema.$defs.pill.properties[key], key).toBeDefined();
      expect(schema.$defs.pill.required, key).not.toContain(key);
    }
  });

  it('accepts the limits, date and contacts on create, and null as unset', () => {
    const ok = CreatePillSchema.safeParse({
      ...base, prnMaxPer24h: 3, prnMinGapMinutes: 240, expiresOn: '2027-03-31',
      prescriberName: '  Dr. Ana  ', prescriberPhone: ' +40 721 000 000 ', pharmacyName: 'Farmacia', pharmacyPhone: '021.000.0000',
    });
    expect(ok.success).toBe(true);
    // Names and numbers are stored trimmed.
    expect(ok.success && ok.data.prescriberName).toBe('Dr. Ana');
    expect(ok.success && ok.data.prescriberPhone).toBe('+40 721 000 000');
    expect(CreatePillSchema.safeParse({
      ...base, prnMaxPer24h: null, prnMinGapMinutes: null, expiresOn: null,
      prescriberName: null, prescriberPhone: null, pharmacyName: null, pharmacyPhone: null,
    }).success).toBe(true);
    expect(CreatePillSchema.safeParse(base).success).toBe(true);
  });

  it.each([
    ['prnMaxPer24h', 0], ['prnMaxPer24h', 49], ['prnMaxPer24h', 1.5],
    ['prnMinGapMinutes', 0], ['prnMinGapMinutes', 2881],
    ['expiresOn', '2027-02-30'], ['expiresOn', '2027-3-1'], ['expiresOn', '0000-01-01'],
    ['prescriberName', ''], ['prescriberName', '   '], ['prescriberName', 'x'.repeat(121)],
    ['pharmacyName', ''],
    ['prescriberPhone', '12'], ['prescriberPhone', 'call me'], ['prescriberPhone', '1'.repeat(41)],
    ['pharmacyPhone', 'abc123'],
  ])('refuses %s = %j', (key, value) => {
    expect(CreatePillSchema.safeParse({ ...base, [key]: value }).success).toBe(false);
    expect(UpdatePillSchema.safeParse({ ...update, [key]: value }).success).toBe(false);
  });

  it('lets an update change only one of the new fields and still refuses an empty update', () => {
    for (const key of fixture.keys) {
      const value = key === 'expiresOn' ? '2027-03-31'
        : key.endsWith('Phone') ? '0211234567'
        : key.endsWith('Name') ? 'Someone'
        : 2;
      expect(UpdatePillSchema.safeParse({ ...update, [key]: value }).success, key).toBe(true);
    }
    expect(UpdatePillSchema.safeParse(update).success).toBe(false);
  });
});
