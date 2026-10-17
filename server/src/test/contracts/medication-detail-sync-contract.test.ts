import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { SyncChangePayloadV2Schema } from '../../modules/sync/sync-payload.js';

const contracts = new URL('../../../../contracts/', import.meta.url);
const readContract = <T>(path: string): T => JSON.parse(readFileSync(new URL(path, contracts), 'utf8')) as T;

/// A pill change row exactly as the server stored it before migration 0025,
/// with none of the reviewed detail keys.
function storedBeforeDetails(): Record<string, unknown> {
  return {
    schemaVersion: 2,
    component: 'stable',
    entityType: 'pill',
    entityId: '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
    operation: 'upsert',
    sourceIdentity: {
      sourceKind: 'pill',
      sourceId: '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
      sourceRevision: '4',
    },
    payload: {
      kind: 'pill',
      id: '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
      profileId: '3f2504e0-4f89-11d3-9a0c-0305e82c3302',
      name: 'Pastila ficat',
      dosage: '1 pastila',
      notes: null,
      color: null,
      currentStock: 12,
      lowStockThreshold: null,
      isPrn: false,
      revision: '4',
      deletedAt: null,
      createdAt: '2026-01-02T03:04:05.000Z',
      updatedAt: '2026-01-02T03:04:05.000Z',
    },
  };
}

describe('medication detail sync', () => {
  it('still reads a pill change stored before the details existed', () => {
    // Every pull re-parses stored rows. Requiring a detail key here would turn
    // the whole history written before migration 0025 into a failed pull.
    const parsed = SyncChangePayloadV2Schema.safeParse(storedBeforeDetails());
    expect(parsed.success, parsed.success ? '' : JSON.stringify(parsed.error.issues)).toBe(true);
  });

  it('carries the reviewed details when they are present', () => {
    const row = storedBeforeDetails();
    const payload = row['payload'] as Record<string, unknown>;
    payload['amountPerUse'] = { version: 1, state: 'known', quantity: '1', unit: 'pastila' };
    payload['packageStrength'] = '500 mg';
    payload['form'] = 'tablet';
    payload['legacyDosageReviewed'] = true;

    const parsed = SyncChangePayloadV2Schema.parse(row);
    expect(parsed.payload).toMatchObject({
      kind: 'pill',
      amountPerUse: { version: 1, state: 'known', quantity: '1', unit: 'pastila' },
      packageStrength: '500 mg',
      form: 'tablet',
      legacyDosageReviewed: true,
      // The wording a person typed is evidence and is never rewritten.
      dosage: '1 pastila',
    });
  });

  it('rejects an amount that claims a quantity without a unit', () => {
    const row = storedBeforeDetails();
    const payload = row['payload'] as Record<string, unknown>;
    payload['amountPerUse'] = { version: 1, state: 'known', quantity: '1' };
    expect(SyncChangePayloadV2Schema.safeParse(row).success).toBe(false);
  });

  it('leaves the detail keys optional in the published contract', () => {
    const schema = readContract<{
      $defs: { pill: { required: string[]; properties: Record<string, unknown> } };
    }>('sync-change-payload-v2.json');
    const pill = schema.$defs.pill;
    for (const key of ['amountPerUse', 'packageStrength', 'form', 'legacyDosageReviewed']) {
      expect(pill.properties[key], key).toBeDefined();
      expect(pill.required, key).not.toContain(key);
    }
  });
});
