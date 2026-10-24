import { and, asc, eq, gt, inArray, isNotNull, sql } from 'drizzle-orm';
import type { Db } from '../../db/client.js';
import { TenantTransactionRunner, type TenantTransaction } from '../../db/tenant-transaction.js';
import { accountSettings, accountSettingsHeads } from '../../db/schema.js';
import { constraintOf, sqlStateOf } from '../../lib/pg-errors.js';
import { ApiError } from '../shared/api-error.js';
import { ErrorCode } from '../shared/errors.js';
import {
  ACCOUNT_SETTING_MAX_VALUE_BYTES,
  ACCOUNT_SETTINGS_MAX_KEYS,
  ACCOUNT_SETTINGS_PAGE_SIZE,
  accountSettingValueSchema,
  type AccountSettingChange,
} from './account-settings.schema.js';

export interface AccountSettingItem {
  key: string;
  value: unknown;
  revision: number;
  updatedAt: string;
}

export interface AccountSettingsPage {
  /** The account's head revision: the newest revision any key holds. */
  revision: number;
  items: AccountSettingItem[];
  /** True when more items follow; continue with afterRevision = the last item's revision. */
  hasMore: boolean;
}

export interface AccountSettingCurrent {
  value: unknown;
  revision: number;
}

export type AccountSettingResult =
  | { key: string; status: 'applied'; revision: number }
  | { key: string; status: 'kept'; current: AccountSettingCurrent }
  | { key: string; status: 'conflict'; current: AccountSettingCurrent };

export interface AccountSettingsPutResponse {
  revision: number;
  results: AccountSettingResult[];
}

/**
 * The jsonb text of a value, as PostgreSQL prints it: ", " and ": " separators
 * and object keys ordered by length, then bytes. Migration 0031 limits
 * octet_length(value::text), so the service must measure the same text.
 */
function jsonbText(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(jsonbText).join(', ')}]`;
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => {
        const byLength = Buffer.byteLength(a, 'utf8') - Buffer.byteLength(b, 'utf8');
        return byLength !== 0 ? byLength : Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
      });
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}: ${jsonbText(v)}`).join(', ')}}`;
  }
  return JSON.stringify(value);
}

export function jsonbBytes(value: unknown): number {
  return Buffer.byteLength(jsonbText(value), 'utf8');
}

function tooLarge(): ApiError {
  return new ApiError(413, ErrorCode.SETTINGS_VALUE_TOO_LARGE, 'Setting value is too large', { retryable: false });
}

/**
 * Validates one change against the allowlist before anything is written. The
 * whole batch is refused when any change is invalid.
 */
export function validateAccountSettingChange(change: AccountSettingChange): void {
  const schema = accountSettingValueSchema(change.key);
  if (!schema) {
    throw new ApiError(400, ErrorCode.SETTINGS_KEY_UNKNOWN, 'Unknown setting key', { retryable: false });
  }
  if (change.value === null) return;
  if (jsonbBytes(change.value) > ACCOUNT_SETTING_MAX_VALUE_BYTES) throw tooLarge();
  if (!schema.safeParse(change.value).success) throw ApiError.validation();
}

/**
 * Per-account settings. Each applied change takes the next number from the
 * account's head counter, so revisions are distinct and a pull pages by them
 * exactly. Conflicts are server-wins per key: a stale base revision changes
 * nothing and returns the stored value.
 */
export class AccountSettingsService {
  private readonly transactions: TenantTransactionRunner;

  constructor(db: Db) {
    this.transactions = new TenantTransactionRunner(db);
  }

  async read(userId: string, afterRevision: number): Promise<AccountSettingsPage> {
    return this.transactions.run(userId, async (tx) => {
      const [head] = await tx.select({ revision: accountSettingsHeads.revision })
        .from(accountSettingsHeads).where(eq(accountSettingsHeads.userId, userId));
      const rows = await tx.select().from(accountSettings).where(and(
        eq(accountSettings.userId, userId),
        gt(accountSettings.revision, afterRevision),
        // A first pull has nothing to delete, so tombstones are left out.
        ...(afterRevision === 0 ? [isNotNull(accountSettings.value)] : []),
      )).orderBy(asc(accountSettings.revision)).limit(ACCOUNT_SETTINGS_PAGE_SIZE + 1);
      const page = rows.slice(0, ACCOUNT_SETTINGS_PAGE_SIZE);
      return {
        revision: head?.revision ?? 0,
        items: page.map((row) => ({
          key: row.key,
          value: row.value ?? null,
          revision: row.revision,
          updatedAt: row.updatedAt.toISOString(),
        })),
        hasMore: rows.length > ACCOUNT_SETTINGS_PAGE_SIZE,
      };
    });
  }

  async write(userId: string, changes: AccountSettingChange[]): Promise<AccountSettingsPutResponse> {
    const seen = new Set<string>();
    for (const change of changes) {
      validateAccountSettingChange(change);
      if (seen.has(change.key)) throw ApiError.validation();
      seen.add(change.key);
    }

    try {
      return await this.writeBatch(userId, changes);
    } catch (error) {
      // The database limit is the last word: a value the service measured as
      // small enough but the constraint refused is still a client error.
      if (sqlStateOf(error) === '23514' && constraintOf(error) === 'account_settings_value_size_check') throw tooLarge();
      throw error;
    }
  }

  private async writeBatch(userId: string, changes: AccountSettingChange[]): Promise<AccountSettingsPutResponse> {
    return this.transactions.run(userId, async (tx) => {
      const head = await this.lockHead(tx, userId);
      const keys = changes.map((change) => change.key);
      const existing = new Map((await tx.select().from(accountSettings).where(and(
        eq(accountSettings.userId, userId),
        inArray(accountSettings.key, keys),
      ))).map((row) => [row.key, row]));

      let liveKeys = await this.countLiveKeys(tx, userId);
      let revision = head;
      const results: AccountSettingResult[] = [];
      for (const change of changes) {
        const row = existing.get(change.key);
        const current: AccountSettingCurrent = { value: row?.value ?? null, revision: row?.revision ?? 0 };
        if (change.ifAbsent === true && row !== undefined) {
          results.push({ key: change.key, status: 'kept', current });
          continue;
        }
        if (change.ifAbsent !== true && change.baseRevision !== current.revision) {
          results.push({ key: change.key, status: 'conflict', current });
          continue;
        }
        const wasLive = row?.value != null;
        const becomesLive = change.value !== null;
        if (!wasLive && becomesLive && liveKeys >= ACCOUNT_SETTINGS_MAX_KEYS) {
          throw new ApiError(400, ErrorCode.SETTINGS_TOO_MANY_KEYS, 'Too many settings', { retryable: false });
        }
        liveKeys += (becomesLive ? 1 : 0) - (wasLive ? 1 : 0);
        revision += 1;
        const now = new Date();
        if (row === undefined) {
          await tx.insert(accountSettings).values({
            userId, key: change.key, value: change.value, revision, updatedAt: now,
          });
        } else {
          await tx.update(accountSettings).set({ value: change.value, revision, updatedAt: now })
            .where(and(eq(accountSettings.userId, userId), eq(accountSettings.key, change.key)));
        }
        results.push({ key: change.key, status: 'applied', revision });
      }
      if (revision !== head) {
        await tx.update(accountSettingsHeads).set({ revision })
          .where(eq(accountSettingsHeads.userId, userId));
      }
      return { revision, results };
    });
  }

  private async lockHead(tx: TenantTransaction, userId: string): Promise<number> {
    await tx.insert(accountSettingsHeads).values({ userId }).onConflictDoNothing();
    const [row] = await tx.select({ revision: accountSettingsHeads.revision })
      .from(accountSettingsHeads).where(eq(accountSettingsHeads.userId, userId)).for('update');
    return row?.revision ?? 0;
  }

  private async countLiveKeys(tx: TenantTransaction, userId: string): Promise<number> {
    const [row] = await tx.select({ count: sql<number>`count(*)::int` }).from(accountSettings)
      .where(and(eq(accountSettings.userId, userId), isNotNull(accountSettings.value)));
    return row?.count ?? 0;
  }
}

/**
 * Clears the settings of records that no longer exist, in the caller's
 * transaction, so a deleted routine or person leaves no key behind. Only keys
 * that currently hold a value are touched; the other devices pull the
 * tombstone and drop their cached copy.
 */
export async function tombstoneAccountSettings(
  tx: TenantTransaction,
  userId: string,
  keys: readonly string[],
): Promise<void> {
  if (keys.length === 0) return;
  const live = await tx.select({ key: accountSettings.key }).from(accountSettings).where(and(
    eq(accountSettings.userId, userId),
    inArray(accountSettings.key, [...keys]),
    isNotNull(accountSettings.value),
  ));
  if (live.length === 0) return;
  await tx.insert(accountSettingsHeads).values({ userId }).onConflictDoNothing();
  const [head] = await tx.select({ revision: accountSettingsHeads.revision })
    .from(accountSettingsHeads).where(eq(accountSettingsHeads.userId, userId)).for('update');
  let revision = head?.revision ?? 0;
  const now = new Date();
  for (const { key } of live) {
    revision += 1;
    await tx.update(accountSettings).set({ value: null, revision, updatedAt: now })
      .where(and(eq(accountSettings.userId, userId), eq(accountSettings.key, key)));
  }
  await tx.update(accountSettingsHeads).set({ revision }).where(eq(accountSettingsHeads.userId, userId));
}
