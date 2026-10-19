import { describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import { CreatePillSchema } from '../pills/pills.schema.js';

// Wire identifiers are 8-4-4-4-12 hex GUIDs. Projection and legacy identifiers
// are not guaranteed to carry RFC 4122 version/variant bits, so validation must
// not require them (zod 4's z.uuid() does; z.guid() does not).
describe('wire identifier validation', () => {
  const base = { name: 'Aspirin' };

  it.each([
    randomUUID(),
    '20000000-0000-0001-0000-000000000aa1',
    '00000000-0000-0000-0000-000000000000',
    'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF',
  ])('accepts %s', (mutationId) => {
    expect(CreatePillSchema.safeParse({ ...base, mutationId }).success).toBe(true);
  });

  it.each([
    '',
    'not-a-uuid',
    '550e8400e29b41d4a716446655440000',
    '{550e8400-e29b-41d4-a716-446655440000}',
    '550e8400-e29b-41d4-a716-44665544000g',
    ' 550e8400-e29b-41d4-a716-446655440000',
  ])('rejects %j', (mutationId) => {
    expect(CreatePillSchema.safeParse({ ...base, mutationId }).success).toBe(false);
  });
});
