import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { openApiDocument } from '../../contracts/openapi.js';
import { ApiError } from '../../modules/shared/api-error.js';
import {
  ACCOUNT_SETTING_KEY_PATTERN,
  ACCOUNT_SETTING_MAX_VALUE_BYTES,
  ACCOUNT_SETTINGS_MAX_CHANGES,
  ACCOUNT_SETTINGS_MAX_KEYS,
  ACCOUNT_SETTINGS_PAGE_SIZE,
  AccountSettingsPutSchema,
  isKnownAccountSettingKey,
} from '../../modules/account-settings/account-settings.schema.js';
import { validateAccountSettingChange } from '../../modules/account-settings/account-settings.service.js';

const contracts = new URL('../../../../contracts/', import.meta.url);
const readContract = <T>(path: string): T => JSON.parse(readFileSync(new URL(path, contracts), 'utf8')) as T;

interface Fixture {
  limits: { maxValueBytes: number; maxKeys: number; maxChangesPerPut: number; pageSize: number };
  valid: Array<{ name: string; key: string; value: unknown }>;
  invalid: Array<{ name: string; key: string; value: unknown; error: string }>;
}

function codeOf(run: () => void): string | undefined {
  try {
    run();
    return undefined;
  } catch (error) {
    return error instanceof ApiError ? error.code : 'NOT_AN_API_ERROR';
  }
}

describe('account settings contract', () => {
  const fixture = readContract<Fixture>('fixtures/account-settings-v1.json');
  const contract = readContract<{ keys: Record<string, string>; limits: Record<string, unknown> }>('account-settings-v1.json');

  it('keeps the contract limits equal to the server limits', () => {
    expect(fixture.limits).toEqual({
      maxValueBytes: ACCOUNT_SETTING_MAX_VALUE_BYTES,
      maxKeys: ACCOUNT_SETTINGS_MAX_KEYS,
      maxChangesPerPut: ACCOUNT_SETTINGS_MAX_CHANGES,
      pageSize: ACCOUNT_SETTINGS_PAGE_SIZE,
    });
    expect(contract.limits).toMatchObject({
      maxValueBytes: ACCOUNT_SETTING_MAX_VALUE_BYTES,
      maxKeysPerAccount: ACCOUNT_SETTINGS_MAX_KEYS,
      maxChangesPerPut: ACCOUNT_SETTINGS_MAX_CHANGES,
      pageSize: ACCOUNT_SETTINGS_PAGE_SIZE,
    });
  });

  it('accepts every valid value of every key and clears any known key with null', () => {
    for (const item of fixture.valid) {
      const change = { key: item.key, value: item.value, baseRevision: 0 };
      expect(codeOf(() => validateAccountSettingChange(change)), item.name).toBeUndefined();
      expect(AccountSettingsPutSchema.safeParse({ changes: [change] }).success, item.name).toBe(true);
      expect(codeOf(() => validateAccountSettingChange({ ...change, value: null })), `${item.name} cleared`).toBeUndefined();
    }
  });

  it('covers every key family of the contract with at least one valid and one invalid case', () => {
    const family = (key: string) => key.replace(/\.[0-9a-f-]{36}$/, '.<id>');
    const documented = Object.keys(contract.keys).map((key) => key.replace(/<[A-Za-z]+Uuid>/, '<id>'));
    const covered = new Set(fixture.valid.map((item) => family(item.key)));
    expect([...covered].sort()).toEqual(documented.sort());
    const refused = new Set(fixture.invalid.filter((item) => item.error !== 'SETTINGS_KEY_UNKNOWN').map((item) => family(item.key)));
    for (const key of documented) expect(refused.has(key), key).toBe(true);
  });

  it('refuses every invalid case with its documented error code', () => {
    for (const item of fixture.invalid) {
      const code = codeOf(() => validateAccountSettingChange({ key: item.key, value: item.value, baseRevision: 0 }));
      expect(code, item.name).toBe(item.error);
    }
  });

  it('knows a key only when it is on the allowlist and shaped right', () => {
    expect(isKnownAccountSettingKey('language')).toBe(true);
    expect(isKnownAccountSettingKey('reminders.routine.00000000-0000-4000-8000-000000000014')).toBe(true);
    expect(isKnownAccountSettingKey('reminders.routine.00000000-0000-4000-8000-00000000001')).toBe(false);
    expect(isKnownAccountSettingKey('reminders.routine.zzzzzzzz-zzzz-4zzz-8zzz-zzzzzzzzzzzz')).toBe(false);
    expect(isKnownAccountSettingKey('constructor')).toBe(false);
    expect(isKnownAccountSettingKey('__proto__')).toBe(false);
    expect(ACCOUNT_SETTING_KEY_PATTERN.test('language\n')).toBe(false);
  });

  it('refuses a put with no value, a duplicate or an extra property', () => {
    const change = { key: 'language', value: 'ro', baseRevision: 0 };
    expect(AccountSettingsPutSchema.safeParse({ changes: [] }).success).toBe(false);
    expect(AccountSettingsPutSchema.safeParse({ changes: [{ key: 'language', baseRevision: 0 }] }).success).toBe(false);
    expect(AccountSettingsPutSchema.safeParse({ changes: [{ ...change, extra: 1 }] }).success).toBe(false);
    expect(AccountSettingsPutSchema.safeParse({ changes: [{ ...change, baseRevision: -1 }] }).success).toBe(false);
    expect(AccountSettingsPutSchema.safeParse({ changes: Array.from({ length: 101 }, () => change) }).success).toBe(false);
    expect(AccountSettingsPutSchema.safeParse({ changes: [{ ...change, ifAbsent: true }] }).success).toBe(true);
  });

  it('publishes the capability and both routes in the OpenAPI document', () => {
    const paths = openApiDocument.paths as Record<string, Record<string, unknown>>;
    expect(Object.keys(paths['/api/v1/account/settings']!).sort()).toEqual(['get', 'put']);
    const schemas = openApiDocument.components.schemas as Record<string, { pattern?: string }>;
    expect(schemas['AccountSettingKeyV1']?.pattern).toBe(ACCOUNT_SETTING_KEY_PATTERN.source);
  });
});
