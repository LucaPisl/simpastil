import { drizzle } from 'drizzle-orm/postgres-js';
import { sql as drizzleSql, type SQL } from 'drizzle-orm';
import { rotateBootstrapProof } from '../modules/admin/bootstrap-rotation.js';
import { logProcessEvent } from '../lib/process-log.js';
import type { PrivilegedCommandContext } from './provision.js';

/** Why a reset was refused; printed to stderr so the operator sees it. */
export class AdminResetRefused extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AdminResetRefused';
  }
}

function refuse(message: string): never {
  // Error messages never reach the structured log (see failure-cause.ts), so the
  // operator-facing reason goes to stderr.
  process.stderr.write(`${message}\n`);
  throw new AdminResetRefused(message);
}

function environmentManagedAdmin(environment: PrivilegedCommandContext['environment']): boolean {
  return ['ADMIN_EMAIL', 'ADMIN_PASSWORD'].some((name) =>
    Boolean(environment[name]?.trim()) || Boolean(environment[`${name}_FILE`]?.trim()));
}

/**
 * Locked-out recovery for the database-backed administrator.
 *
 * In one transaction: deletes the administrator row (password, TOTP secret and
 * its embedded backup codes), deletes the administrator's backup_codes rows
 * (user_id IS NULL), revokes every administrator refresh token, appends an
 * audit entry and rotates a fresh 30-minute bootstrap proof. The console's
 * setup page then creates the administrator again from an email and a new
 * password, exactly as on first install. Accounts, devices and medication
 * data are never read or written.
 */
export async function resetAdmin({ sql, environment }: PrivilegedCommandContext): Promise<void> {
  if (environmentManagedAdmin(environment)) {
    refuse(
      'reset-admin refused: this deployment manages the administrator from ADMIN_EMAIL and '
      + 'ADMIN_PASSWORD. Change those values and restart the API instead.',
    );
  }

  const database = drizzle(sql);
  const proof = await database.transaction(async (tx) => {
    // Serialize with admin session issuance and rotation, which lock this row.
    const configured = await tx.execute(drizzleSql`SELECT id FROM admin_config FOR UPDATE`);
    if (configured.length === 0) {
      refuse(
        'reset-admin refused: no database-backed administrator exists. '
        + 'Run "provision rotate-bootstrap" and use the console setup page instead.',
      );
    }

    await tx.execute(drizzleSql`DELETE FROM backup_codes WHERE user_id IS NULL`);
    await tx.execute(drizzleSql`UPDATE admin_refresh_tokens SET revoked = TRUE WHERE revoked = FALSE`);
    await tx.execute(drizzleSql`DELETE FROM admin_config`);
    // No secrets, identifiers or the administrator's email in the entry.
    await tx.execute(drizzleSql`
      INSERT INTO audit_logs (actor, action, target_type, target_id, metadata)
      VALUES ('provision', 'admin.access_reset', 'admin', NULL, '{"via":"provision reset-admin"}'::jsonb)
    `);

    // admin_bootstrap_state is writable only by the deployment authority owner;
    // its guard trigger stays in force. Do this last: the role cannot write the
    // tables above.
    return rotateBootstrapProof(async (callback) => {
      await tx.execute(drizzleSql`SET LOCAL ROLE deployment_authority_owner`);
      return callback({
        execute: async <Row = Record<string, unknown>>(query: unknown): Promise<Row[]> =>
          await tx.execute(query as SQL) as unknown as Row[],
      });
    });
  });

  logProcessEvent('info', 'provision.admin_reset');
  process.stdout.write(`${JSON.stringify({
    proof: proof.proof,
    generation: proof.generation,
    expiresAt: proof.expiresAt.toISOString(),
  })}\n`);
}
