import { describe, expect, it } from 'vitest';
import { ComponentCursorCodec } from '../../modules/sync/component-cursor.js';

describe('component cursor integrity and tenant binding', () => {
  const codec = new ComponentCursorCodec('unit-test-signing-secret-that-is-not-production');
  const claims = {
    component: 'stable' as const,
    contractVersion: 2 as const,
    afterSequence: '9007199254740993',
    throughSequence: '9223372036854775807',
    pageSize: 100,
  };
  const now = Date.UTC(2026, 8, 25, 12, 0, 0);

  it('round-trips decimal sequence boundaries without number conversion', () => {
    const token = codec.encode(claims, 'tenant-a', now);
    expect(codec.decode(token, 'tenant-a', now)).toMatchObject(claims);
  });

  it('rejects altered, cross-tenant, and expired cursors', () => {
    const token = codec.encode(claims, 'tenant-a', now);
    const [payload, signature] = token.split('.');
    const changedToken = `${payload}.${signature![0] === 'A' ? 'B' : 'A'}${signature!.slice(1)}`;
    expect(() => codec.decode(changedToken, 'tenant-a', now)).toThrow('Sync cursor is invalid or expired');
    expect(() => codec.decode(token, 'tenant-b', now)).toThrow('Sync cursor is invalid or expired');
    expect(() => codec.decode(token, 'tenant-a', now + 91 * 24 * 60 * 60 * 1000)).toThrow('Sync cursor is invalid or expired');
  });

  it('binds all bridge contracts and rejects unsupported component versions', () => {
    const bridgeV1 = codec.encode({ ...claims, component: 'medicationBridge', contractVersion: 1 }, 'tenant-a', now);
    const bridgeV2 = codec.encode({ ...claims, component: 'medicationBridge', contractVersion: 2 }, 'tenant-a', now);
    const bridgeV3 = codec.encode({ ...claims, component: 'medicationBridge', contractVersion: 3 }, 'tenant-a', now);
    const bridgeV4 = codec.encode({ ...claims, component: 'medicationBridge', contractVersion: 4 }, 'tenant-a', now);
    const bridgeV5 = codec.encode({ ...claims, component: 'medicationBridge', contractVersion: 5 }, 'tenant-a', now);
    expect(codec.decode(bridgeV1, 'tenant-a', now)).toMatchObject({ component: 'medicationBridge', contractVersion: 1 });
    expect(codec.decode(bridgeV2, 'tenant-a', now)).toMatchObject({ component: 'medicationBridge', contractVersion: 2 });
    expect(codec.decode(bridgeV3, 'tenant-a', now)).toMatchObject({ component: 'medicationBridge', contractVersion: 3 });
    expect(codec.decode(bridgeV4, 'tenant-a', now)).toMatchObject({ component: 'medicationBridge', contractVersion: 4 });
    expect(codec.decode(bridgeV5, 'tenant-a', now)).toMatchObject({ component: 'medicationBridge', contractVersion: 5 });
    expect(() => codec.encode({ ...claims, component: 'stable', contractVersion: 1 }, 'tenant-a', now)).toThrow();
    expect(() => codec.encode({ ...claims, component: 'stable', contractVersion: 3 }, 'tenant-a', now)).toThrow();
    expect(() => codec.encode({ ...claims, component: 'stable', contractVersion: 4 }, 'tenant-a', now)).toThrow();
    expect(() => codec.encode({ ...claims, component: 'stable', contractVersion: 5 }, 'tenant-a', now)).toThrow();
  });
});
