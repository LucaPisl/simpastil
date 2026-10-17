import { sql } from 'drizzle-orm';
import type { Db } from './client.js';

export type TenantTransaction = Parameters<Parameters<Db['transaction']>[0]>[0];

/**
 * Every API transaction uses the app_user pool and installs transaction-local
 * tenant context before any query. RLS without this context returns no rows;
 * callers must still include explicit tenant predicates in every operation.
 */
export class TenantTransactionRunner {
  constructor(private readonly db: Db) {}

  run<T>(userId: string, operation: (tx: TenantTransaction) => Promise<T>): Promise<T> {
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('app.current_user_id', ${userId}, true)`);
      return operation(tx);
    });
  }
}
