import { eq } from 'drizzle-orm';
import { z } from 'zod';
import type { Db } from '../../db/client.js';
import { deploymentManifest } from '../../db/schema.js';
import { sendApiError } from '../shared/api-error.js';
import { ApiError } from '../shared/api-error.js';
import { ErrorCode } from '../shared/errors.js';
import type { FastifyInstance } from 'fastify';
import { RELEASE_URL_PREFIX, VERSION_RE, type LatestRelease } from '../updates/release.js';
import { readServerVersion } from '../updates/update-checker.js';

const CapabilitiesV1Schema = z.object({
  apiNamespace: z.literal('v1'),
  contracts: z.object({
    refreshRecovery: z.literal(1),
    componentSync: z.literal(2),
    legacySplitReconciliation: z.literal(1),
    medicationBridgeCommands: z.literal(1),
    medicationBridgeSync: z.literal(1),
    medicationBridgeParentSync: z.literal(2),
    medicationBridgeAncestorSync: z.literal(3),
    medicationBridgeOccurrenceSync: z.literal(4),
    medicationBridgePrnCommands: z.literal(1),
    medicationBridgePrnSync: z.literal(5),
    // 3 adds the `miss` action and the `missed` occurrence state; a build
    // that only speaks 2 must update before it merges those events.
    medicationCommands: z.literal(3),
    // The reviewed medication details (amount per use, package strength, form
    // and the reviewed flag) travel with the pill. A build that does not see
    // this key keeps them on the device it reviewed them on.
    medicationDetails: z.literal(1),
  }).strict(),
  // Additive: bridge commands accept status 'pending' (undo). Not a contract version.
  bridgeUndo: z.literal(true),
  // Additive: the ledger accepts the `miss` action. Implied by medicationCommands 3.
  recordedMiss: z.literal(true),
  // Additive: the PRN command route stays open after ledger activation and
  // moves stock there. Without it an active-ledger client cannot send PRN doses.
  ledgerPrn: z.literal(true),
  medicationLedgerActive: z.boolean(),
  minimumClientBuild: z.number().int().positive(),
  serverRelease: z.string().min(1).max(128),
  // Additive: the running server's own version, and (only after a successful
  // daily check) the newest published release. Clients ignore what they do not know.
  serverVersion: z.string().min(1).max(32),
  latestServerVersion: z.string().regex(VERSION_RE).optional(),
  latestClientBuild: z.number().int().positive().optional(),
  latestReleaseUrl: z.string().max(256).startsWith(RELEASE_URL_PREFIX).optional(),
}).strict();

export type CapabilitiesV1 = z.infer<typeof CapabilitiesV1Schema>;

export interface CapabilitiesUpdates {
  serverVersion: string;
  current(): LatestRelease | undefined;
}

export default async function capabilitiesRoutes(
  fastify: FastifyInstance,
  opts: { db: Db; updates?: CapabilitiesUpdates },
) {
  const serverVersion = opts.updates?.serverVersion ?? readServerVersion();
  fastify.get('/capabilities', async (request, reply) => {
    try {
      const [manifest] = await opts.db.select({
        ledgerActivated: deploymentManifest.ledgerActivated,
        minimumClientBuild: deploymentManifest.enforcedMinimumClientBuild,
        serverRelease: deploymentManifest.releaseId,
      }).from(deploymentManifest).where(eq(deploymentManifest.singletonKey, true));
      if (!manifest) throw new ApiError(503, ErrorCode.INTERNAL, 'Server capabilities are unavailable');
      const latest = opts.updates?.current();
      const capabilities = CapabilitiesV1Schema.parse({
        apiNamespace: 'v1',
        contracts: {
          refreshRecovery: 1,
          componentSync: 2,
          legacySplitReconciliation: 1,
          medicationBridgeCommands: 1,
          medicationBridgeSync: 1,
          medicationBridgeParentSync: 2,
          medicationBridgeAncestorSync: 3,
          medicationBridgeOccurrenceSync: 4,
          medicationBridgePrnCommands: 1,
          medicationBridgePrnSync: 5,
          medicationCommands: 3,
          medicationDetails: 1,
        },
        bridgeUndo: true,
        recordedMiss: true,
        ledgerPrn: true,
        medicationLedgerActive: manifest.ledgerActivated,
        minimumClientBuild: manifest.minimumClientBuild,
        serverRelease: manifest.serverRelease,
        serverVersion,
        ...(latest ? latest : {}),
      });
      return reply.status(200).send(capabilities);
    } catch (error) {
      return sendApiError(reply, request, error);
    }
  });
}
