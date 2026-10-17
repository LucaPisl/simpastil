import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { openApiDocument, openApiRouteInventory } from '../../contracts/openapi.js';

const fixtures = new URL('./fixtures/', import.meta.url);
const readFixture = (name: string) => JSON.parse(readFileSync(new URL(name, fixtures), 'utf8')) as Record<string, unknown>;

describe('checked API contract', () => {
  it('documents every source operation exactly once under the versioned namespace', () => {
    const inventoryKeys = openApiRouteInventory.map(({ method, path }) => `${method} ${path}`);
    expect(new Set(inventoryKeys).size).toBe(inventoryKeys.length);
    expect(inventoryKeys.every((operation) => operation.includes('/api/v1/'))).toBe(true);

    const paths = openApiDocument.paths as Record<string, Record<string, unknown>>;
    const documentedKeys = Object.entries(paths).flatMap(([path, methods]) =>
      Object.keys(methods).map((method) => `${method} ${path}`));
    expect([...documentedKeys].sort()).toEqual([...inventoryKeys].sort());
  });

  it('keeps legacy success bodies route-specific and freezes the established list wrappers', () => {
    const legacy = readFixture('legacy-v1.json');
    expect(legacy['contract']).toBe('legacy-v1');
    expect(openApiDocument.info.description).toContain('never globally wrapped');
    expect(legacy['successfulResponses']).toEqual({
      listProfiles: { status: 200, body: { profiles: [] } },
      listPills: { status: 200, body: { pills: [] } },
      listSchedules: { status: 200, body: { schedules: [] } },
      listDoseLogs: { status: 200, body: { logs: [] } },
    });
  });

  it('keeps bridge and active-ledger fixtures on their versioned camelCase wire contracts', () => {
    const bridge = readFixture('bridge-v1.json');
    const legacyHistory = readFixture('legacy-estimated-history-v1.json');
    const v2 = readFixture('v2.json');
    expect(bridge['contractVersion']).toBe(1);
    expect((bridge['syncItem'] as { component?: string }).component).toBe('medicationBridge');
    expect(legacyHistory['timeZoneStatus']).toBe('legacy_unknown');
    expect(v2['contractVersion']).toBe(2);
    expect(Object.keys(bridge['command'] as object)).toContain('transactionCorrelationId');
    expect(Object.keys(v2['occurrenceCommand'] as object)).toEqual(expect.arrayContaining([
      'occurrenceId', 'occurrenceKey', 'baseVersion', 'actualTimeKnown', 'rebasesCommandId',
    ]));
    expect(openApiDocument.paths['/api/v1/medication/bridge/commands']).toBeDefined();
    expect(openApiDocument.paths['/api/v1/medication/commands']).toBeDefined();
    expect(openApiDocument.paths['/api/v1/sync/{component}']).toBeDefined();
  });
});
