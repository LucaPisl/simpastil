import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { openApiDocument } from '../../contracts/openapi.js';
import { DELETED_ACCOUNT_MARKER_DAYS } from '../../lib/deleted-accounts.js';
import { ACCOUNT_EXPORT_TABLES } from '../../modules/account/account-export.js';
import {
  AccountDeleteRequestSchema,
  ChangeEmailRequestSchema,
  ConfirmEmailChangeRequestSchema,
  EMAIL_CHANGE_TOKEN_TTL_MS,
} from '../../modules/account/account.schema.js';

const contracts = new URL('../../../../contracts/', import.meta.url);
const readContract = <T>(path: string): T => JSON.parse(readFileSync(new URL(path, contracts), 'utf8')) as T;

describe('account self-service contract', () => {
  const fixture = readContract<{ tokenTtlHours: number; markerDays: number; exportTables: string[] }>(
    'fixtures/account-self-service-v1.json');
  const contract = readContract<{ export: { tables: string[] }; delete: { markerDays: number } }>('account-self-service-v1.json');

  it('keeps the contract limits equal to the server limits', () => {
    expect(fixture.tokenTtlHours * 3_600_000).toBe(EMAIL_CHANGE_TOKEN_TTL_MS);
    expect(fixture.markerDays).toBe(DELETED_ACCOUNT_MARKER_DAYS);
    expect(contract.delete.markerDays).toBe(DELETED_ACCOUNT_MARKER_DAYS);
  });

  it('lists the exported tables exactly as the exporter does', () => {
    const keys = ACCOUNT_EXPORT_TABLES.map((spec) => spec.key);
    expect(fixture.exportTables).toEqual(keys);
    expect(contract.export.tables).toEqual(keys);
  });

  it('refuses extra properties and weak input', () => {
    expect(AccountDeleteRequestSchema.safeParse({ password: 'x' }).success).toBe(true);
    expect(AccountDeleteRequestSchema.safeParse({ password: 'x', extra: 1 }).success).toBe(false);
    expect(AccountDeleteRequestSchema.safeParse({}).success).toBe(false);
    expect(ChangeEmailRequestSchema.safeParse({ password: 'x', newEmail: 'not-an-email' }).success).toBe(false);
    expect(ChangeEmailRequestSchema.safeParse({ password: 'x', newEmail: ' a@b.co ' }).success).toBe(true);
    expect(ConfirmEmailChangeRequestSchema.safeParse({ token: 'short' }).success).toBe(false);
    expect(ConfirmEmailChangeRequestSchema.safeParse({ token: 'a'.repeat(43) }).success).toBe(true);
  });

  it('publishes the routes and the capability in the OpenAPI document', () => {
    const paths = openApiDocument.paths as Record<string, Record<string, unknown>>;
    expect(Object.keys(paths['/api/v1/account/summary']!)).toEqual(['get']);
    expect(Object.keys(paths['/api/v1/account/export']!)).toEqual(['get']);
    expect(Object.keys(paths['/api/v1/account/delete']!)).toEqual(['post']);
    expect(Object.keys(paths['/api/v1/auth/change-email']!)).toEqual(['post']);
    expect(Object.keys(paths['/api/v1/auth/change-email/confirm']!)).toEqual(['post']);
  });
});
