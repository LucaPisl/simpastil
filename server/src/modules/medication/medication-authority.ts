import { sql } from 'drizzle-orm';
import type { TenantTransaction } from '../../db/tenant-transaction.js';

/** Read and share-lock deployment authority through its least-privilege SQL API. */
export async function lockMedicationLedgerAuthority(
  tx: TenantTransaction,
): Promise<boolean | null> {
  const [row] = await tx.execute<{ ledgerActivated: boolean }>(sql`
    SELECT authority.ledger_activated AS "ledgerActivated"
    FROM public.lock_medication_ledger_authority() AS authority
  `);
  return row?.ledgerActivated ?? null;
}
