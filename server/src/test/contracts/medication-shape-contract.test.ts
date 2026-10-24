import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { CreatePillSchema, UpdatePillSchema } from '../../modules/pills/pills.schema.js';
import { MEDICATION_SHAPES } from '../../modules/shared/medication-shape.js';
import { SyncChangePayloadV2Schema } from '../../modules/sync/sync-payload.js';

const contracts = new URL('../../../../contracts/', import.meta.url);
const readContract = <T>(path: string): T => JSON.parse(readFileSync(new URL(path, contracts), 'utf8')) as T;

interface ShapeFixture {
  knownShapes: string[];
  cases: Array<{ name: string; expectedShape: string | null; change: unknown }>;
}

describe('medication shape contract', () => {
  const fixture = readContract<ShapeFixture>('fixtures/pill-shape-v1.json');

  it('keeps the fixture list in step with the server enum', () => {
    expect(fixture.knownShapes).toEqual([...MEDICATION_SHAPES]);
  });

  it('reads every fixture row through the strict payload schema, an unknown shape included', () => {
    // Every stored change row is re-parsed on each pull, so a shape name this
    // release does not know must not fail it.
    expect(fixture.cases.map((item) => item.name)).toEqual(expect.arrayContaining([
      'pill-with-shape', 'pill-shape-missing', 'pill-shape-null', 'pill-shape-unknown-future-value',
    ]));
    for (const item of fixture.cases) {
      const parsed = SyncChangePayloadV2Schema.safeParse(item.change);
      expect(parsed.success, item.name + (parsed.success ? '' : JSON.stringify(parsed.error.issues))).toBe(true);
    }
  });

  it('declares shape optional in the published contract', () => {
    const schema = readContract<{
      $defs: { pill: { required: string[]; properties: Record<string, unknown> } };
    }>('sync-change-payload-v2.json');
    expect(schema.$defs.pill.properties['shape']).toBeDefined();
    expect(schema.$defs.pill.required).not.toContain('shape');
  });

  it('accepts only the published names when a shape is written', () => {
    const base = { mutationId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301', name: 'Magnefar' };
    for (const shape of MEDICATION_SHAPES) {
      expect(CreatePillSchema.safeParse({ ...base, shape }).success, shape).toBe(true);
    }
    expect(CreatePillSchema.safeParse({ ...base, shape: null }).success).toBe(true);
    expect(CreatePillSchema.safeParse(base).success).toBe(true);
    expect(CreatePillSchema.safeParse({ ...base, shape: 'hexagon' }).success).toBe(false);
    expect(CreatePillSchema.safeParse({ ...base, shape: 'Round' }).success).toBe(false);
  });

  it('lets an update change only the shape, and rejects an unknown one', () => {
    const base = { mutationId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301', baseRevision: '1' };
    expect(UpdatePillSchema.safeParse({ ...base, shape: 'diamond' }).success).toBe(true);
    expect(UpdatePillSchema.safeParse({ ...base, shape: 'hexagon' }).success).toBe(false);
    // An update that names nothing to change is still refused.
    expect(UpdatePillSchema.safeParse(base).success).toBe(false);
  });
});
