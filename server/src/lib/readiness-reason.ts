/**
 * Why the readiness probe said "not ready", from a closed list so the reason
 * is safe to log. The `/health/ready` response body never carries it.
 */
export const READINESS_REASONS = [
  'database_unreachable',
  'migrations_unreadable',
  'runtime_role_unsafe',
  'migrations_behind',
  'migrations_incompatible',
  'release_mismatch',
  'contract_not_ready',
] as const;
export type ReadinessReason = (typeof READINESS_REASONS)[number];

export function isReadinessReason(value: unknown): value is ReadinessReason {
  return typeof value === 'string' && (READINESS_REASONS as readonly string[]).includes(value);
}

export const READINESS_REASON_TEXT: Record<ReadinessReason, string> = {
  database_unreachable: 'the database cannot be reached or did not answer the readiness query',
  migrations_unreadable: 'the migration files bundled in this image cannot be read',
  runtime_role_unsafe: 'the API is not connected as the restricted app_user role',
  migrations_behind: 'the database migrations are behind this server image',
  migrations_incompatible: 'the database has newer migrations than this image can work with',
  release_mismatch: 'the database was prepared for a different release than this server expects',
  contract_not_ready: 'the deployment manifest is incomplete, so migration has not finished',
};
