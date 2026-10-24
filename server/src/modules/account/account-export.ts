import { once } from 'node:events';
import { PassThrough } from 'node:stream';
import { sql, type SQL } from 'drizzle-orm';
import type { Db } from '../../db/client.js';

/**
 * Every public table is either listed here (exported) or in
 * ACCOUNT_EXPORT_EXCLUDED with the reason it is left out. A test walks
 * information_schema and fails when a new table is in neither list, so a
 * future table cannot be forgotten silently.
 */
export interface ExportTableSpec {
  /** The key under `tables` in the file (camelCase). */
  key: string;
  table: string;
  /** SQL predicate on alias `t` that limits the rows to the account. */
  owner: (userId: string) => SQL;
  /** Columns left out of the file (secrets). */
  exclude?: readonly string[];
  /** Keyset column for paging; omit for tiny tables read whole. */
  pageBy?: string;
  /** Stable order for tables without a page key. */
  orderBy?: string;
  /** Rows per page; defaults to 1000. Small for tables of large rows. */
  pageSize?: number;
  /** A bytea column written as base64 under `<column>Base64` instead of the hex text of to_jsonb. */
  base64Column?: string;
}

const own = (userId: string) => sql`t.user_id = ${userId}::uuid`;
const profileOwned = (userId: string) => sql`t.profile_id IN (SELECT id FROM public.profiles WHERE user_id = ${userId}::uuid)`;
const pillOwned = (userId: string) => sql`t.pill_id IN (
  SELECT p.id FROM public.pills p JOIN public.profiles pr ON pr.id = p.profile_id WHERE pr.user_id = ${userId}::uuid)`;
const scheduleOwned = (userId: string) => sql`t.schedule_id IN (
  SELECT s.id FROM public.schedules s JOIN public.pills p ON p.id = s.pill_id
  JOIN public.profiles pr ON pr.id = p.profile_id WHERE pr.user_id = ${userId}::uuid)`;

/** Tables in dependency order, so the file reads people first. */
export const ACCOUNT_EXPORT_TABLES: readonly ExportTableSpec[] = [
  { key: 'profiles', table: 'profiles', owner: own, pageBy: 'id' },
  { key: 'pills', table: 'pills', owner: profileOwned, pageBy: 'id' },
  // The photo bytes are written as base64 and read a few at a time: a page of
  // 1000 rows would hold hundreds of megabytes.
  { key: 'pillPhotos', table: 'pill_photos', owner: own, pageBy: 'pill_id', pageSize: 10, base64Column: 'bytes' },
  { key: 'schedules', table: 'schedules', owner: pillOwned, pageBy: 'id' },
  { key: 'doseLogs', table: 'dose_logs', owner: scheduleOwned, pageBy: 'id' },
  { key: 'medicationOccurrences', table: 'medication_occurrences', owner: own, pageBy: 'id' },
  { key: 'occurrenceEvents', table: 'occurrence_events', owner: own, pageBy: 'id' },
  { key: 'inventoryEvents', table: 'inventory_events', owner: own, pageBy: 'id' },
  { key: 'accountSettings', table: 'account_settings', owner: own, orderBy: 'key' },
  {
    key: 'devices',
    table: 'api_keys',
    owner: own,
    exclude: ['key_hash', 'encrypted_key'],
    pageBy: 'id',
  },
  {
    key: 'accountLog',
    table: 'audit_logs',
    owner: (userId) => sql`t.target_type IN ('user', 'account') AND t.target_id = ${userId}`,
    exclude: ['ip_address'],
    pageBy: 'id',
  },
];

/** Public tables deliberately not in the file, each with its reason. */
export const ACCOUNT_EXPORT_EXCLUDED: Readonly<Record<string, string>> = {
  users: 'Written as the account block (email, dates, 2FA on or off), never with its hashes or secrets.',
  refresh_tokens: 'Sign-in secrets.',
  backup_codes: '2FA secrets.',
  password_reset_tokens: 'Secrets.',
  email_change_tokens: 'Secrets.',
  invitation_tokens: 'Secrets, and not about this account.',
  account_settings_heads: 'Sync counter.',
  sync_changes: 'Sync internals; the rows themselves are exported.',
  sync_stream_counters: 'Sync counter.',
  entity_mutation_receipts: 'Replay protection for sync, not user data.',
  medication_command_receipts: 'Replay protection for sync, not user data.',
  preactivation_medication_receipts: 'Migration bookkeeping.',
  medication_handoff_journal: 'Migration bookkeeping.',
  legacy_medication_history: 'Migration evidence; the resulting doses are exported.',
  migration_issues: 'Migration bookkeeping.',
  deleted_account_markers: 'Not about a live account.',
  outbox_messages: 'Mail delivery queue, encrypted.',
  admin_config: 'Server administration.',
  admin_refresh_tokens: 'Server administration.',
  admin_bootstrap_state: 'Server administration.',
  server_settings: 'Server administration.',
  deployment_manifest: 'Server administration.',
  deployment_authority_events: 'Server administration.',
};

export const ACCOUNT_EXPORT_FORMAT = 'simpastil-account-export';
export const ACCOUNT_EXPORT_VERSION = 1;
const PAGE_SIZE = 1000;

function camel(key: string): string {
  return key.replace(/_([a-z0-9])/g, (_m, c: string) => c.toUpperCase());
}

function camelRow(row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) out[camel(key)] = value;
  return out;
}

function exclusion(spec: ExportTableSpec): SQL {
  const list = [...(spec.exclude ?? []), ...(spec.base64Column ? [spec.base64Column] : [])];
  const base = list.length === 0
    ? sql`to_jsonb(t)`
    : sql`to_jsonb(t) - ARRAY[${sql.join(list.map((c) => sql`${c}`), sql`, `)}]::text[]`;
  if (!spec.base64Column) return base;
  const column = sql.raw(`t.${spec.base64Column}`);
  return sql`${base} || jsonb_build_object(${`${spec.base64Column}_base64`}::text, translate(encode(${column}, 'base64'), E'\n', ''))`;
}

type Tx = Parameters<Parameters<Db['transaction']>[0]>[0];

async function readPage(tx: Tx, spec: ExportTableSpec, userId: string, after: string | null) {
  const table = sql.raw(`public.${spec.table}`);
  const cursor = spec.pageBy
    ? (after === null ? sql`` : sql` AND t.${sql.raw(spec.pageBy)}::text > ${after}`)
    : sql``;
  const order = sql.raw(`t.${spec.pageBy ?? spec.orderBy ?? 'ctid'}`);
  const limit = spec.pageBy ? sql` LIMIT ${spec.pageSize ?? PAGE_SIZE}` : sql``;
  const result = await tx.execute(sql`
    SELECT ${exclusion(spec)} AS doc, ${spec.pageBy ? sql`t.${sql.raw(spec.pageBy)}::text` : sql`NULL`} AS page_key
    FROM ${table} AS t
    WHERE ${spec.owner(userId)}${cursor}
    ORDER BY ${order}${limit}
  `);
  return result as unknown as Array<{ doc: Record<string, unknown>; page_key: string | null }>;
}

export interface ExportAccountBlock {
  id: string;
  email: string;
  createdAt: string;
  twoFactorEnabled: boolean;
}

/**
 * Streams the account as one JSON document. The read runs in a single
 * read-only snapshot, so the file is internally consistent, and holds one page
 * in memory at a time. Failure while streaming destroys the response so the
 * client never mistakes a half file for a whole one.
 */
export function streamAccountExport(db: Db, userId: string, account: ExportAccountBlock, exportedAt: Date): PassThrough {
  const out = new PassThrough();

  const write = async (chunk: string): Promise<void> => {
    if (out.destroyed) throw new Error('export stream closed');
    if (!out.write(chunk)) {
      const closed = once(out, 'close').then(() => { throw new Error('export stream closed'); });
      await Promise.race([once(out, 'drain'), closed]);
    }
  };

  const run = async (): Promise<void> => {
    await db.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      await write(`{"format":${JSON.stringify(ACCOUNT_EXPORT_FORMAT)},"version":${ACCOUNT_EXPORT_VERSION},`
        + `"exportedAt":${JSON.stringify(exportedAt.toISOString())},`
        + `"account":${JSON.stringify(account)},"tables":{`);
      let firstTable = true;
      for (const spec of ACCOUNT_EXPORT_TABLES) {
        await write(`${firstTable ? '' : ','}${JSON.stringify(spec.key)}:[`);
        firstTable = false;
        let first = true;
        let after: string | null = null;
        for (;;) {
          const rows = await readPage(tx, spec, userId, after);
          if (rows.length > 0) {
            const body = rows.map((r) => JSON.stringify(camelRow(r.doc))).join(',');
            await write(`${first ? '' : ','}${body}`);
            first = false;
          }
          if (!spec.pageBy || rows.length < (spec.pageSize ?? PAGE_SIZE)) break;
          after = rows[rows.length - 1]!.page_key;
        }
        await write(']');
      }
      await write('}}');
    }, { isolationLevel: 'repeatable read', accessMode: 'read only' });
    out.end();
  };

  run().catch((error: unknown) => { out.destroy(error instanceof Error ? error : new Error('export failed')); });
  return out;
}
