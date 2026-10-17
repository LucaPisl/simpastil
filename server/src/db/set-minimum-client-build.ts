import type { PrivilegedCommandContext } from './provision.js';

export async function setMinimumClientBuild({ sql, args }: PrivilegedCommandContext): Promise<void> {
  const [buildText, changeFlag, changeReference] = args ?? [];
  if (!buildText || !/^[1-9]\d*$/.test(buildText) || changeFlag !== '--change-ref'
      || !changeReference || changeReference.length > 256) {
    throw new Error('Usage: set-minimum-client-build <positive-build> --change-ref <non-secret-reference>');
  }
  const build = Number(buildText);
  if (!Number.isSafeInteger(build)) throw new Error('Client build must be a safe positive integer');

  await sql.begin(async (transaction) => {
    const rows = await transaction.unsafe<{
      contractVersion: string;
      ledgerActivated: boolean;
      enforcedMinimumClientBuild: number;
      targetMinimumClientBuild: number;
    }[]>(`
      SELECT contract_version::text AS "contractVersion",
        ledger_activated AS "ledgerActivated",
        enforced_minimum_client_build AS "enforcedMinimumClientBuild",
        target_minimum_client_build AS "targetMinimumClientBuild"
      FROM public.deployment_manifest
      WHERE singleton_key IS TRUE
      FOR UPDATE
    `);
    const manifest = rows[0];
    if (!manifest) throw new Error('Deployment authority manifest is unavailable');
    if (build > manifest.targetMinimumClientBuild) {
      throw new Error('Enforced client build cannot exceed the immutable artifact target');
    }
    if (build === manifest.enforcedMinimumClientBuild) {
      throw new Error('Enforced client build already has the requested value');
    }
    await transaction.unsafe(`
      SELECT public.set_deployment_authority(
        $1::bigint, $2::boolean, $3::integer, 'minimum_client_build', $4::text
      )
    `, [manifest.contractVersion, manifest.ledgerActivated, build, changeReference]);
  });
}
