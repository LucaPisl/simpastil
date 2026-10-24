import { MEDICATION_SHAPES } from '../modules/shared/medication-shape.js';

type HttpMethod = 'get' | 'post' | 'put' | 'patch' | 'delete';
type SecurityKind = 'none' | 'apiKey' | 'user' | 'admin';
type RouteDefinition = {
  method: HttpMethod;
  path: string;
  operationId: string;
  tag: string;
  summary: string;
  security?: SecurityKind;
  status?: number;
  alternateSuccessStatus?: number;
  request?: string;
  query?: string;
  response?: string;
  clientBuildGate?: boolean;
  /** The body (request) or the response is the raw JPEG of a medication photo. */
  jpeg?: 'request' | 'response';
};

const routes: RouteDefinition[] = [
  { method: 'get', path: '/api/v1/health/live', operationId: 'healthLive', tag: 'health', summary: 'Liveness probe' },
  { method: 'get', path: '/api/v1/health/ready', operationId: 'healthReady', tag: 'health', summary: 'Readiness probe' },
  { method: 'get', path: '/api/v1/health', operationId: 'health', tag: 'health', summary: 'Health status' },
  { method: 'get', path: '/api/v1/capabilities', operationId: 'getCapabilities', tag: 'capabilities', summary: 'Read dynamic API and medication authority capabilities', response: 'CapabilitiesV1' },
  { method: 'post', path: '/api/v1/auth/login', operationId: 'login', tag: 'auth', summary: 'Authenticate a user', security: 'apiKey', request: 'AnyJsonObject', status: 200 },
  { method: 'post', path: '/api/v1/auth/register', operationId: 'register', tag: 'auth', summary: 'Register a user', security: 'apiKey', request: 'AnyJsonObject', status: 201 },
  { method: 'post', path: '/api/v1/auth/refresh', operationId: 'refreshSession', tag: 'auth', summary: 'Refresh a user session', security: 'apiKey', request: 'AnyJsonObject', status: 200 },
  { method: 'post', path: '/api/v1/auth/refresh/recoverable', operationId: 'recoverRefreshSession', tag: 'auth', summary: 'Recover an exact refresh rotation', security: 'apiKey', request: 'AnyJsonObject', status: 200 },
  { method: 'post', path: '/api/v1/auth/logout', operationId: 'logout', tag: 'auth', summary: 'Revoke a refresh session', security: 'apiKey', request: 'AnyJsonObject', status: 204 },
  { method: 'post', path: '/api/v1/auth/logout-all', operationId: 'logoutAll', tag: 'auth', summary: 'Revoke all user sessions', security: 'user', status: 204 },
  { method: 'post', path: '/api/v1/auth/change-password', operationId: 'changePassword', tag: 'auth', summary: 'Change the user password', security: 'user', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/auth/2fa/setup', operationId: 'setupUserTwoFactor', tag: 'auth', summary: 'Start user two-factor setup', security: 'user' },
  { method: 'post', path: '/api/v1/auth/2fa/enable', operationId: 'enableUserTwoFactor', tag: 'auth', summary: 'Enable user two-factor authentication', security: 'user', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/auth/2fa/disable', operationId: 'disableUserTwoFactor', tag: 'auth', summary: 'Disable user two-factor authentication', security: 'user', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/auth/2fa/backup-codes', operationId: 'rotateUserBackupCodes', tag: 'auth', summary: 'Rotate user backup codes', security: 'user', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/auth/2fa/challenge', operationId: 'completeUserTwoFactorChallenge', tag: 'auth', summary: 'Complete a user two-factor challenge', security: 'apiKey', request: 'AnyJsonObject' },
  { method: 'get', path: '/api/v1/auth/verify-key', operationId: 'verifyApiKey', tag: 'auth', summary: 'Verify an API key', security: 'apiKey' },
  { method: 'post', path: '/api/v1/auth/device', operationId: 'registerDevice', tag: 'auth', summary: 'Register a device', security: 'user', request: 'AnyJsonObject' },
  { method: 'patch', path: '/api/v1/auth/device', operationId: 'updateDevice', tag: 'auth', summary: 'Update device metadata', security: 'user', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/auth/forgot-password', operationId: 'requestPasswordReset', tag: 'recovery', summary: 'Request a password reset', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/auth/reset-password', operationId: 'resetPassword', tag: 'recovery', summary: 'Reset a password', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/auth/invite/accept', operationId: 'acceptInvitation', tag: 'recovery', summary: 'Accept an invitation', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/admin/setup', operationId: 'setupAdmin', tag: 'admin', summary: 'Set up the administrator', request: 'AnyJsonObject', status: 201 },
  { method: 'get', path: '/api/v1/admin/status', operationId: 'getAdminStatus', tag: 'admin', summary: 'Read administrator setup status' },
  { method: 'post', path: '/api/v1/admin/auth/login', operationId: 'adminLogin', tag: 'admin', summary: 'Authenticate the administrator', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/admin/auth/refresh', operationId: 'adminRefresh', tag: 'admin', summary: 'Refresh an administrator session', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/admin/auth/change-password', operationId: 'adminChangePassword', tag: 'admin', summary: 'Change the administrator password', security: 'admin', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/admin/auth/logout', operationId: 'adminLogout', tag: 'admin', summary: 'End this administrator sign-in and revoke its refresh tokens; repeating it is a no-op', security: 'admin', status: 204 },
  { method: 'post', path: '/api/v1/admin/auth/logout-all', operationId: 'adminLogoutAll', tag: 'admin', summary: 'Revoke administrator sessions', security: 'admin', status: 204 },
  { method: 'get', path: '/api/v1/admin/auth/2fa/status', operationId: 'adminTwoFactorStatus', tag: 'admin', summary: 'Read whether administrator two-factor authentication is available and enabled, and how many backup codes remain', security: 'admin', response: 'AdminTwoFactorStatusV1' },
  { method: 'post', path: '/api/v1/admin/auth/2fa/setup', operationId: 'adminTwoFactorSetup', tag: 'admin', summary: 'Start administrator two-factor setup', security: 'admin' },
  { method: 'post', path: '/api/v1/admin/auth/2fa/enable', operationId: 'adminTwoFactorEnable', tag: 'admin', summary: 'Enable administrator two-factor authentication', security: 'admin', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/admin/auth/2fa/disable', operationId: 'adminTwoFactorDisable', tag: 'admin', summary: 'Disable administrator two-factor authentication', security: 'admin', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/admin/auth/2fa/backup-codes', operationId: 'adminBackupCodes', tag: 'admin', summary: 'Rotate administrator backup codes', security: 'admin', request: 'AnyJsonObject' },
  { method: 'post', path: '/api/v1/admin/auth/2fa/challenge', operationId: 'adminTwoFactorChallenge', tag: 'admin', summary: 'Complete an administrator two-factor challenge', request: 'AnyJsonObject' },
  { method: 'get', path: '/api/v1/admin/keys', operationId: 'listApiKeys', tag: 'admin', summary: 'List API keys', security: 'admin' },
  { method: 'post', path: '/api/v1/admin/keys', operationId: 'createApiKey', tag: 'admin', summary: 'Create an API key', security: 'admin', request: 'AnyJsonObject', status: 201 },
  { method: 'get', path: '/api/v1/admin/keys/{id}/reveal', operationId: 'revealApiKey', tag: 'admin', summary: 'Exchange a one-time API key reveal', security: 'admin' },
  { method: 'delete', path: '/api/v1/admin/keys/{id}', operationId: 'deleteApiKey', tag: 'admin', summary: 'Revoke an API key', security: 'admin', status: 204 },
  { method: 'post', path: '/api/v1/admin/invites', operationId: 'createInvitation', tag: 'admin', summary: 'Queue an invitation', security: 'admin', request: 'AnyJsonObject', status: 202 },
  { method: 'get', path: '/api/v1/admin/users/{id}/keys', operationId: 'listUserApiKeys', tag: 'admin', summary: 'List a user’s API keys', security: 'admin' },
  { method: 'post', path: '/api/v1/admin/users/{id}/keys', operationId: 'createUserApiKey', tag: 'admin', summary: 'Create a user API key', security: 'admin', request: 'AnyJsonObject', status: 201 },
  { method: 'get', path: '/api/v1/admin/users', operationId: 'listUsers', tag: 'admin', summary: 'List users', security: 'admin' },
  { method: 'get', path: '/api/v1/admin/users/{id}/devices', operationId: 'listUserDevices', tag: 'admin', summary: 'List user devices', security: 'admin' },
  { method: 'delete', path: '/api/v1/admin/users/{id}/devices/{familyId}', operationId: 'revokeUserDevice', tag: 'admin', summary: 'Revoke a user device', security: 'admin', status: 204 },
  { method: 'delete', path: '/api/v1/admin/users/{id}', operationId: 'deleteUser', tag: 'admin', summary: 'Delete a user', security: 'admin', status: 204 },
  { method: 'get', path: '/api/v1/admin/settings', operationId: 'getServerSettings', tag: 'admin', summary: 'Read the password reset settings', security: 'admin', response: 'ServerSettingsV1' },
  { method: 'put', path: '/api/v1/admin/settings', operationId: 'updateServerSettings', tag: 'admin', summary: 'Update the password reset settings; email mode needs SMTP', security: 'admin', request: 'UpdateServerSettingsV1', response: 'ServerSettingsV1' },
  { method: 'post', path: '/api/v1/admin/users/{id}/reset-link', operationId: 'issueUserResetLink', tag: 'admin', summary: 'Issue a one-time password reset link for a user; the link is returned once and replaces any earlier link', security: 'admin', response: 'ResetLinkIssuedV1' },
  { method: 'get', path: '/api/v1/admin/email-status', operationId: 'getEmailStatus', tag: 'admin', summary: 'Read email delivery status: whether email is configured and the effective mode, plus the count and time of recent permanent failures', security: 'admin', response: 'EmailStatusV1' },
  { method: 'get', path: '/api/v1/admin/audit-logs', operationId: 'listAdminAuditLogs', tag: 'admin', summary: 'List administrator audit logs, newest first, filtered by action and time range', security: 'admin', query: 'AdminAuditLogsQuery', response: 'AdminAuditLogsV1' },
  { method: 'get', path: '/api/v1/profiles', operationId: 'listProfiles', tag: 'profiles', summary: 'List profiles', security: 'user' },
  { method: 'post', path: '/api/v1/profiles', operationId: 'createProfile', tag: 'profiles', summary: 'Create a profile', security: 'user', request: 'CreateProfileV1', status: 201, clientBuildGate: true },
  { method: 'patch', path: '/api/v1/profiles/{id}', operationId: 'updateProfile', tag: 'profiles', summary: 'Update a profile', security: 'user', request: 'UpdateProfileV1', clientBuildGate: true },
  { method: 'delete', path: '/api/v1/profiles/{id}', operationId: 'deleteProfile', tag: 'profiles', summary: 'Delete a profile', security: 'user', request: 'DeleteVersionedEntityV1', status: 204, clientBuildGate: true },
  { method: 'get', path: '/api/v1/profiles/{profileId}/pills', operationId: 'listPills', tag: 'pills', summary: 'List profile medications', security: 'user' },
  { method: 'post', path: '/api/v1/profiles/{profileId}/pills', operationId: 'createPill', tag: 'pills', summary: 'Create a medication', security: 'user', request: 'CreatePillV1', status: 201, clientBuildGate: true },
  { method: 'patch', path: '/api/v1/profiles/{profileId}/pills/{id}', operationId: 'updatePill', tag: 'pills', summary: 'Update a medication', security: 'user', request: 'UpdatePillV1', clientBuildGate: true },
  { method: 'delete', path: '/api/v1/profiles/{profileId}/pills/{id}', operationId: 'deletePill', tag: 'pills', summary: 'Delete a medication', security: 'user', request: 'DeleteVersionedEntityV1', status: 204, clientBuildGate: true },
  { method: 'get', path: '/api/v1/pills/{id}/photo', operationId: 'getPillPhoto', tag: 'pills', summary: 'Read the photo of a medication (404 without one)', security: 'user', jpeg: 'response' },
  { method: 'put', path: '/api/v1/pills/{id}/photo', operationId: 'putPillPhoto', tag: 'pills', summary: 'Set or replace the photo of a medication; the server checks the JPEG and bumps the pill revision', security: 'user', jpeg: 'request', response: 'PillPhotoV1', clientBuildGate: true },
  { method: 'delete', path: '/api/v1/pills/{id}/photo', operationId: 'deletePillPhoto', tag: 'pills', summary: 'Remove the photo of a medication (repeating it is a no-op)', security: 'user', status: 204, clientBuildGate: true },
  { method: 'get', path: '/api/v1/pills/{pillId}/schedules', operationId: 'listSchedules', tag: 'schedules', summary: 'List medication schedules', security: 'user' },
  { method: 'post', path: '/api/v1/pills/{pillId}/schedules', operationId: 'createSchedule', tag: 'schedules', summary: 'Create a medication schedule', security: 'user', request: 'CreateScheduleV1', status: 201, clientBuildGate: true },
  { method: 'patch', path: '/api/v1/pills/{pillId}/schedules/{id}', operationId: 'updateSchedule', tag: 'schedules', summary: 'Update a medication schedule', security: 'user', request: 'UpdateScheduleV1', clientBuildGate: true },
  { method: 'delete', path: '/api/v1/pills/{pillId}/schedules/{id}', operationId: 'deleteSchedule', tag: 'schedules', summary: 'Delete a medication schedule', security: 'user', request: 'DeleteVersionedEntityV1', status: 204, clientBuildGate: true },
  { method: 'post', path: '/api/v1/pills/{pillId}/schedules/{id}/repair', operationId: 'repairSchedule', tag: 'schedules', summary: 'Resolve schedule review and choose the materialization boundary', security: 'user', request: 'ScheduleRepairRequest', clientBuildGate: true },
  { method: 'post', path: '/api/v1/logs/{scheduleId}', operationId: 'legacyCreateDoseLog', tag: 'medication-legacy', summary: 'Legacy split write (rejected; use the bridge command)', security: 'user', request: 'AnyJsonObject', status: 409 },
  { method: 'get', path: '/api/v1/profiles/{profileId}/logs', operationId: 'listDoseLogs', tag: 'medication-legacy', summary: 'Read legacy dose logs', security: 'user' },
  { method: 'patch', path: '/api/v1/logs/{id}', operationId: 'legacyUpdateDoseLog', tag: 'medication-legacy', summary: 'Legacy split write (rejected; use the bridge command)', security: 'user', request: 'AnyJsonObject', status: 409 },
  { method: 'delete', path: '/api/v1/logs/{id}', operationId: 'legacyDeleteDoseLog', tag: 'medication-legacy', summary: 'Legacy split write (rejected; use the bridge command)', security: 'user', request: 'AnyJsonObject', status: 409 },
  { method: 'post', path: '/api/v1/medication/commands', operationId: 'executeMedicationCommand', tag: 'medication', summary: 'Apply an active-ledger occurrence command', security: 'user', request: 'MedicationCommandV2', response: 'MedicationCommandResult', clientBuildGate: true },
  { method: 'post', path: '/api/v1/medication/moved-history', operationId: 'createMovedHistory', tag: 'medication', summary: 'Create the past scheduled occurrences of care that moved from a device (idempotent; history is then recorded with the normal commands)', security: 'user', request: 'MovedHistoryRequestV1', response: 'MovedHistoryResult', clientBuildGate: true },
  { method: 'post', path: '/api/v1/medication/inventory/commands', operationId: 'executeInventoryCommand', tag: 'medication', summary: 'Start or adjust tracked inventory', security: 'user', request: 'InventoryCommandV2', response: 'InventoryCommandResult', clientBuildGate: true },
  { method: 'post', path: '/api/v1/medication/bridge/commands', operationId: 'executeBridgeMedicationCommand', tag: 'medication-bridge', summary: 'Apply an atomic inactive-ledger bridge command', security: 'user', request: 'MedicationBridgeCommandV1', response: 'MedicationBridgeCommandResult', clientBuildGate: true },
  { method: 'post', path: '/api/v1/medication/bridge/prn/commands', operationId: 'executeBridgePrnCommand', tag: 'medication-bridge', summary: 'Record or undo exact PRN care; after ledger activation it also moves stock (ledgerPrn)', security: 'user', request: 'BridgePrnCommandV1', response: 'MedicationCommandResult', clientBuildGate: true },
  { method: 'post', path: '/api/v1/medication/legacy-split/reconcile', operationId: 'reconcileLegacySplit', tag: 'medication-reconciliation', summary: 'Record or resolve a legacy split checkpoint', security: 'user', request: 'LegacySplitCheckpointV1', response: 'LegacySplitReconciliationResult', status: 200, alternateSuccessStatus: 201, clientBuildGate: true },
  { method: 'get', path: '/api/v1/sync/{component}', operationId: 'getComponentSync', tag: 'sync', summary: 'Read one fixed-boundary component snapshot page', security: 'user', query: 'ComponentSyncQuery', response: 'ComponentSyncResponseV2', clientBuildGate: true },
  { method: 'get', path: '/api/v1/account/settings', operationId: 'getAccountSettings', tag: 'account', summary: 'Read the settings that follow the account, newest revisions after afterRevision', security: 'user', query: 'AccountSettingsQuery', response: 'AccountSettingsPageV1', clientBuildGate: true },
  { method: 'put', path: '/api/v1/account/settings', operationId: 'putAccountSettings', tag: 'account', summary: 'Write account settings; server-wins per key', security: 'user', request: 'AccountSettingsPutRequestV1', response: 'AccountSettingsPutResponseV1', clientBuildGate: true },
  { method: 'get', path: '/api/v1/account/summary', operationId: 'getAccountSummary', tag: 'account', summary: 'Read what the account holds, counted from live rows', security: 'user', response: 'AccountSummaryV1' },
  { method: 'get', path: '/api/v1/account/export', operationId: 'exportAccount', tag: 'account', summary: 'Download the whole account as one JSON file (streamed; secrets are never included)', security: 'user', response: 'AccountExportV1' },
  { method: 'post', path: '/api/v1/account/delete', operationId: 'deleteAccount', tag: 'account', summary: 'Delete the account and everything in it after the password (and 2FA code) is checked again', security: 'user', request: 'AccountDeleteRequestV1', status: 204 },
  { method: 'post', path: '/api/v1/auth/change-email', operationId: 'changeEmail', tag: 'auth', summary: 'Change the sign-in email after the password (and 2FA code) is checked again; confirmed from a mailed link when mail is configured', security: 'user', request: 'ChangeEmailRequestV1', response: 'ChangeEmailResponseV1' },
  { method: 'post', path: '/api/v1/auth/change-email/confirm', operationId: 'confirmEmailChange', tag: 'auth', summary: 'Confirm a pending email change from the mailed link (no sign-in needed)', request: 'ConfirmEmailChangeRequestV1', response: 'ChangeEmailResponseV1' },
];

const securityFor: Record<SecurityKind, Array<Record<string, string[]>>> = {
  none: [],
  apiKey: [{ ApiKeyAuth: [] }],
  user: [{ ApiKeyAuth: [], BearerAuth: [] }],
  admin: [{ AdminBearerAuth: [] }],
};

function pathParameters(path: string) {
  return [...path.matchAll(/\{([^}]+)\}/g)].map((match) => ({
    name: match[1]!,
    in: 'path',
    required: true,
    schema: match[1] === 'component'
      ? { type: 'string', enum: ['account', 'stable', 'medication-bridge', 'medication'] }
      : { type: 'string', format: 'uuid' },
  }));
}

function makeOperation(route: RouteDefinition) {
  const status = route.status ?? (route.method === 'get' ? 200 : 200);
  const responseSchema = route.response ?? 'AnyJson';
  const successResponse = status === 204
    ? { description: 'No content; existing v1 status and success shape are preserved.' }
    : {
      description: route.path.startsWith('/api/v1/') && !route.path.includes('/medication/') && route.path !== '/api/v1/capabilities'
        ? 'Successful route-specific response; this OpenAPI document does not wrap or rewrite the v1 body.'
        : 'Successful response.',
      content: { 'application/json': { schema: { $ref: `#/components/schemas/${responseSchema}` } } },
    };
  const responses: Record<string, unknown> = {
    [String(status)]: successResponse,
    '400': { $ref: '#/components/responses/ApiError' },
    '401': { $ref: '#/components/responses/ApiError' },
    '409': { $ref: '#/components/responses/ApiError' },
    '500': { $ref: '#/components/responses/ApiError' },
  };
  if (route.alternateSuccessStatus !== undefined) {
    responses[String(route.alternateSuccessStatus)] = successResponse;
  }
  if (route.path === '/api/v1/capabilities') {
    responses['503'] = { $ref: '#/components/responses/ApiError' };
  }
  if (route.clientBuildGate) responses['426'] = { $ref: '#/components/responses/ApiError' };
  if (route.path === '/api/v1/medication/commands') responses['422'] = { $ref: '#/components/responses/ApiError' };
  if (route.method === 'get') responses['404'] = { $ref: '#/components/responses/ApiError' };
  const operation: Record<string, unknown> = {
    operationId: route.operationId,
    tags: [route.tag],
    summary: route.summary,
    security: securityFor[route.security ?? 'none'],
    parameters: [
      ...pathParameters(route.path),
      ...(route.clientBuildGate ? [{
        name: 'X-Simpastil-Client-Build',
        in: 'header',
        required: false,
        description: 'Positive integer app build. Omission means build 1. Builds below capabilities.minimumClientBuild receive 426 on this marked mutation.',
        schema: { type: 'integer', minimum: 1 },
      }] : []),
      ...(route.query === 'ComponentSyncQuery' ? [
        { name: 'contractVersion', in: 'query', required: true, description: 'Contract 2 for account, stable, and medication; contracts 1 through 5 for medication-bridge while inactive. Contract 3 supplies complete historical ancestry, contract 4 adds exact scheduled occurrences, and contract 5 adds exact PRN occurrences and events.', schema: { type: 'integer', enum: [1, 2, 3, 4, 5] } },
        { name: 'cursor', in: 'query', required: false, description: 'Opaque authenticated cursor bound to tenant, component, and contract; do not parse or modify.', schema: { type: 'string', maxLength: 4096 } },
        { name: 'afterSequence', in: 'query', required: false, description: 'Completed sequence checkpoint for the next traversal. Mutually exclusive with cursor.', schema: { type: 'string', pattern: '^(0|[1-9][0-9]{0,18})$' } },
        { name: 'pageSize', in: 'query', required: false, description: 'First-page size (1–200); continuation pages retain this value.', schema: { type: 'integer', minimum: 1, maximum: 200 } },
      ] : []),
      ...(route.query === 'AccountSettingsQuery' ? [
        { name: 'afterRevision', in: 'query', required: false, description: 'Return only keys whose revision is greater than this (default 0). A first pull (0) leaves out cleared keys.', schema: { type: 'integer', minimum: 0, default: 0 } },
      ] : []),
      ...(route.query === 'AdminAuditLogsQuery' ? [
        { name: 'limit', in: 'query', required: false, description: 'Page size (1–200, default 50).', schema: { type: 'integer', minimum: 1, maximum: 200 } },
        { name: 'offset', in: 'query', required: false, description: 'Entries to skip (default 0).', schema: { type: 'integer', minimum: 0 } },
        { name: 'action', in: 'query', required: false, description: 'Only entries with exactly this action, such as key.create.', schema: { type: 'string', minLength: 1, maxLength: 100 } },
        { name: 'from', in: 'query', required: false, description: 'Only entries at or after this instant.', schema: { type: 'string', format: 'date-time' } },
        { name: 'to', in: 'query', required: false, description: 'Only entries strictly before this instant.', schema: { type: 'string', format: 'date-time' } },
      ] : []),
    ],
    responses,
  };
  if (route.jpeg === 'response') {
    responses[String(status)] = {
      description: 'The stored JPEG (at most 1600 px a side and 512 KiB, no metadata). ETag is the sha256 in quotes.',
      content: { 'image/jpeg': { schema: { type: 'string', format: 'binary' } } },
    };
  }
  if (route.jpeg === 'request') {
    responses['413'] = { $ref: '#/components/responses/ApiError' };
    responses['422'] = { $ref: '#/components/responses/ApiError' };
    operation['requestBody'] = {
      required: true,
      description: 'A baseline or progressive JPEG of at most 524288 bytes and 1600 px a side, with no APP1 (Exif, XMP) segment. Re-sending the same bytes changes nothing.',
      content: { 'image/jpeg': { schema: { type: 'string', format: 'binary' } } },
    };
  }
  if (route.request) {
    operation['requestBody'] = {
      required: true,
      content: { 'application/json': { schema: { $ref: `#/components/schemas/${route.request}` } } },
    };
  }
  if (route.clientBuildGate) operation['x-client-build-gate'] = true;
  return operation;
}

const paths: Record<string, Record<string, unknown>> = {};
for (const route of routes) {
  const pathItem = paths[route.path] ?? {};
  if (pathItem[route.method]) throw new Error(`Duplicate OpenAPI operation: ${route.method} ${route.path}`);
  pathItem[route.method] = makeOperation(route);
  paths[route.path] = pathItem;
}

const uuid = { type: 'string', format: 'uuid' };
const positiveRevision = { type: 'string', pattern: '^[1-9][0-9]{0,18}$', maxLength: 19 };
const nullableText = (maxLength: number) => ({ type: ['string', 'null'], maxLength });
// The silhouette picked for a medication. Writes accept only the published
// names; the sync item reads any short string (see sync-payload.ts).
const medicationShape = { enum: [...MEDICATION_SHAPES, null] };
// Limits, expiry and contacts of a medication (migration 0033). Null clears a
// value on update; an absent key keeps it. The phone numbers are personal data.
const medicationDetailsExtraProperties = {
  prnMaxPer24h: { type: ['integer', 'null'], minimum: 1, maximum: 48 },
  prnMinGapMinutes: { type: ['integer', 'null'], minimum: 1, maximum: 2880 },
  expiresOn: { type: ['string', 'null'], format: 'date' },
  prescriberName: { type: ['string', 'null'], minLength: 1, maxLength: 120 },
  prescriberPhone: { type: ['string', 'null'], pattern: '^[0-9+()./#* -]{3,40}$' },
  pharmacyName: { type: ['string', 'null'], minLength: 1, maxLength: 120 },
  pharmacyPhone: { type: ['string', 'null'], pattern: '^[0-9+()./#* -]{3,40}$' },
};
const AnyJsonObject = { type: 'object', additionalProperties: true };

export const openApiDocument = {
  openapi: '3.1.0',
  info: {
    title: 'Simpastil API',
    version: '1.3.0',
    description: 'Versioned API contracts. Successful v1 bodies remain route-specific and are never globally wrapped. GET /api/v1/capabilities publishes dynamic activation and enforced minimum build. Only explicitly marked authenticated mutations are build-gated; missing X-Simpastil-Client-Build means build 1. Clients must not select a legacy write path when capability discovery fails.',
  },
  servers: [{ url: '/' }],
  tags: [
    { name: 'capabilities' }, { name: 'health' }, { name: 'auth' }, { name: 'recovery' }, { name: 'sync' }, { name: 'account' },
    { name: 'admin' }, { name: 'profiles' }, { name: 'pills' }, { name: 'schedules' },
    { name: 'medication-legacy' }, { name: 'medication' }, { name: 'medication-bridge' },
    { name: 'medication-reconciliation' },
  ],
  paths,
  components: {
    securitySchemes: {
      ApiKeyAuth: { type: 'apiKey', in: 'header', name: 'x-api-key' },
      BearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' },
      AdminBearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' },
    },
    responses: {
      ApiError: {
        description: 'Versioned safe API error; correlationId is included and details are code-allowlisted.',
        headers: {
          'X-Correlation-Id': { description: 'Request correlation identifier shared with the error body.', schema: { type: 'string', format: 'uuid' } },
        },
        content: { 'application/json': {
          schema: { $ref: '#/components/schemas/ApiError' },
          examples: {
            clientUpgradeRequired: { summary: 'Client build is below the enforced minimum', value: { error: { code: 'CLIENT_UPGRADE_REQUIRED', message: 'Update the app before using this operation', retryable: false, correlationId: '00000000-0000-4000-8000-000000000001', details: {} } } },
            medicationBridgeRequired: { summary: 'Legacy split write is closed', value: { error: { code: 'MEDICATION_BRIDGE_REQUIRED', message: 'Use the medication bridge command', retryable: false, correlationId: '00000000-0000-4000-8000-000000000002', details: {} } } },
            contractNotActive: { summary: 'Active medication contract is not enabled', value: { error: { code: 'CONTRACT_NOT_ACTIVE', message: 'Medication contract is not active', retryable: false, correlationId: '00000000-0000-4000-8000-000000000003', details: {} } } },
            reconciliationRequired: { summary: 'Legacy evidence requires reconciliation', value: { error: { code: 'MEDICATION_RECONCILIATION_REQUIRED', message: 'Reconcile retained legacy evidence before continuing', retryable: false, correlationId: '00000000-0000-4000-8000-000000000004', details: {} } } },
            staleBase: { summary: 'A command used a stale base revision', value: { error: { code: 'CONFLICT_STALE_UPDATE', message: 'The resource changed; refresh and rebase the command', retryable: false, correlationId: '00000000-0000-4000-8000-000000000005', details: {} } } },
          },
        } },
      },
    },
    schemas: {
      AnyJson: { oneOf: [AnyJsonObject, { type: 'array', items: {} }, { type: 'string' }, { type: 'boolean' }, { type: 'number' }, { type: 'null' }] },
      AnyJsonObject,
      ApiError: {
        type: 'object', additionalProperties: false, required: ['error'],
        properties: { error: {
          type: 'object', additionalProperties: false,
          required: ['code', 'message', 'retryable', 'correlationId', 'details'],
          properties: {
            code: { type: 'string', description: 'Stable machine-readable error code. Medication contracts include CONTRACT_NOT_ACTIVE, MEDICATION_BRIDGE_REQUIRED, MEDICATION_RECONCILIATION_REQUIRED, CONFLICT_STALE_UPDATE, MISS_NOT_ALLOWED (422), and CLIENT_UPGRADE_REQUIRED.' }, message: { type: 'string' }, retryable: { type: 'boolean' },
            correlationId: { type: 'string' }, details: { type: 'object', additionalProperties: true },
          },
        } },
      },
      CapabilitiesV1: {
        type: 'object', additionalProperties: false,
        required: ['apiNamespace', 'bridgeUndo', 'contracts', 'emailChange', 'emailReset', 'medicationLedgerActive', 'minimumClientBuild', 'recordedMiss', 'scheduleWindows', 'movedHistory', 'ledgerPrn', 'serverRelease', 'serverVersion'],
        properties: {
          apiNamespace: { const: 'v1' },
          bridgeUndo: { const: true, description: 'Additive: bridge medication commands accept status pending (undo of a dose).' },
          recordedMiss: { const: true, description: 'Additive: the medication ledger accepts the miss action and the missed occurrence state (medicationCommands 3).' },
          scheduleWindows: { const: true, description: 'Additive: the server accepts interval (every N days) schedules and start and end dates (everyDays, anchorDate, startDate, endDate) and writes version 3 occurrence snapshots for them. An account that stores them is held to client build 7 by the per-account build gate.' },
          movedHistory: { const: true, description: 'Additive: POST /medication/moved-history creates past scheduled occurrences for care that moved from a device to this server.' },
          emailReset: { enum: ['available', 'unavailable'], description: 'Additive: whether this server emails password reset links (the effective reset mode is email and SMTP is configured). Carries nothing about any account or about delivery failures.' },
          emailChange: { enum: ['confirm', 'immediate'], description: 'Additive: whether a changed sign-in email must be confirmed from a link sent to the new address (confirm: mail is configured) or applies at once (immediate). Carries nothing about any account.' },
          ledgerPrn: { const: true, description: 'Additive: the PRN command route accepts take and undo after ledger activation and applies their stock effect.' },
          contracts: { type: 'object', additionalProperties: false,
            required: ['componentSync', 'legacySplitReconciliation', 'medicationBridgeCommands', 'medicationBridgeSync', 'medicationBridgeParentSync', 'medicationBridgeAncestorSync', 'medicationBridgeOccurrenceSync', 'medicationBridgePrnCommands', 'medicationBridgePrnSync', 'medicationCommands', 'medicationDetails', 'medicationShapes', 'fractionalStock', 'medicationRecordedBy', 'accountSettings', 'accountSelfService'],
            properties: {
              componentSync: { const: 2 }, legacySplitReconciliation: { const: 1 },
              medicationBridgeCommands: { const: 1 }, medicationBridgeSync: { const: 1 }, medicationBridgeParentSync: { const: 2 }, medicationBridgeAncestorSync: { const: 3 }, medicationBridgeOccurrenceSync: { const: 4 }, medicationBridgePrnCommands: { const: 1 }, medicationBridgePrnSync: { const: 5 }, medicationCommands: { const: 3 }, medicationDetails: { const: 1 }, medicationShapes: { const: 1 }, medicationDetailsExtra: { const: 1 }, medicationPhoto: { const: 1 }, fractionalStock: { const: 1 }, medicationRecordedBy: { const: 1 }, accountSettings: { const: 1 }, accountSelfService: { const: 1 },
            },
          },
          medicationLedgerActive: { type: 'boolean', description: 'Dynamic database authority state; not an image setting.' },
          minimumClientBuild: { type: 'integer', minimum: 1, description: 'Dynamic enforced minimum. The artifact target is intentionally not exposed.' },
          serverRelease: { type: 'string', minLength: 1, maxLength: 128, description: 'Non-secret server release identifier.' },
          serverVersion: { type: 'string', minLength: 1, maxLength: 32, description: 'Additive: the running server version.' },
          latestServerVersion: { type: 'string', pattern: '^\\d+\\.\\d+\\.\\d+$', description: 'Additive: newest published release version. Present only after a successful daily update check.' },
          latestClientBuild: { type: 'integer', minimum: 1, description: 'Additive: app build of the newest published release. Present with latestServerVersion.' },
          latestReleaseUrl: { type: 'string', maxLength: 256, pattern: '^https://github\\.com/LucaPisl/simpastil/releases/', description: 'Additive: release page of the newest published release. Present with latestServerVersion.' },
        },
      },
      ServerSettingsV1: {
        type: 'object', additionalProperties: false,
        required: ['passwordResetMode', 'effectivePasswordResetMode', 'resetLinkLifetimeMinutes', 'smtpConfigured', 'updatedAt'],
        properties: {
          passwordResetMode: { enum: ['email', 'manual', null], description: 'Stored choice; null means automatic (email when SMTP is configured, otherwise manual).' },
          effectivePasswordResetMode: { enum: ['email', 'manual'] },
          resetLinkLifetimeMinutes: { type: 'integer', minimum: 5, maximum: 1440 },
          smtpConfigured: { type: 'boolean' },
          updatedAt: { type: ['string', 'null'], format: 'date-time' },
        },
      },
      UpdateServerSettingsV1: {
        type: 'object', additionalProperties: false, minProperties: 1,
        description: 'Omitted fields stay unchanged. Selecting email while SMTP is not configured returns 409 ADMIN_EMAIL_RESET_UNAVAILABLE.',
        properties: {
          passwordResetMode: { enum: ['email', 'manual', null] },
          resetLinkLifetimeMinutes: { type: 'integer', minimum: 5, maximum: 1440 },
        },
      },
      EmailStatusV1: {
        type: 'object', additionalProperties: false,
        required: ['configured', 'effectiveMode', 'recentPermanentFailures', 'lastPermanentFailureAt'],
        description: 'Aggregates only: no recipients, message contents or error text. Failures and the last timestamp both cover the last seven days; the timestamp is null when there was none in that window.',
        properties: {
          configured: { type: 'boolean', description: 'Whether SMTP_HOST is set.' },
          effectiveMode: { enum: ['email', 'manual'] },
          recentPermanentFailures: { type: 'integer', minimum: 0 },
          lastPermanentFailureAt: { type: ['string', 'null'], format: 'date-time' },
        },
      },
      AdminTwoFactorStatusV1: {
        type: 'object', additionalProperties: false,
        required: ['available', 'enabled', 'backupCodesRemaining'],
        description: 'Counts and flags only: never a secret, a hash or a code.',
        properties: {
          available: { type: 'boolean', description: 'False for an environment-managed administrator without a database row to hold a secret.' },
          enabled: { type: 'boolean' },
          backupCodesRemaining: { type: 'integer', minimum: 0 },
        },
      },
      AdminAuditLogsV1: {
        type: 'object', additionalProperties: false,
        required: ['logs', 'hasMore'],
        description: 'Newest first. Entries hold actions, targets, the client IP and a small metadata object; never a password, token or code.',
        properties: {
          logs: {
            type: 'array',
            items: {
              type: 'object', additionalProperties: false,
              required: ['id', 'actor', 'action', 'targetType', 'targetId', 'metadata', 'ipAddress', 'createdAt'],
              properties: {
                id: { type: 'string', format: 'uuid' },
                actor: { type: 'string' },
                action: { type: 'string' },
                targetType: { type: 'string' },
                targetId: { type: ['string', 'null'] },
                metadata: { type: ['object', 'null'], additionalProperties: true },
                ipAddress: { type: ['string', 'null'] },
                createdAt: { type: 'string', format: 'date-time' },
              },
            },
          },
          hasMore: { type: 'boolean', description: 'True when another page follows at offset + limit.' },
        },
      },
      ResetLinkIssuedV1: {
        type: 'object', additionalProperties: false,
        required: ['link', 'expiresAt'],
        description: 'Returned once, with Cache-Control no-store. The token is never stored in plain text or written to the audit log.',
        properties: { link: { type: 'string', maxLength: 512 }, expiresAt: { type: 'string', format: 'date-time' } },
      },
      ScheduleDocument: {
        type: 'object', additionalProperties: false,
        required: ['hour', 'minute', 'frequency', 'frequencyDays', 'isActive', 'timeZone'],
        properties: {
          hour: { type: 'integer', minimum: 0, maximum: 23 }, minute: { type: 'integer', minimum: 0, maximum: 59 },
          frequency: { enum: ['daily', 'weekly', 'custom', 'prn'] },
          frequencyDays: { oneOf: [{ type: 'array', items: { type: 'integer', minimum: 1, maximum: 7 } }, { type: 'null' }] },
          isActive: { type: 'boolean' }, timeZone: { type: 'string', maxLength: 128, format: 'iana-time-zone' },
        },
      },
      CreateProfileV1: {
        type: 'object', additionalProperties: false,
        required: ['mutationId', 'name'],
        properties: { mutationId: uuid, id: uuid, name: { type: 'string', minLength: 1, maxLength: 100 }, avatarEmoji: { type: 'string', minLength: 1, maxLength: 32 }, isActive: { type: 'boolean' } },
      },
      UpdateProfileV1: {
        type: 'object', additionalProperties: false,
        required: ['mutationId', 'baseRevision'],
        properties: { mutationId: uuid, baseRevision: positiveRevision, name: { type: 'string', minLength: 1, maxLength: 100 }, avatarEmoji: { type: 'string', minLength: 1, maxLength: 32 }, isActive: { type: 'boolean' } },
      },
      DeleteVersionedEntityV1: {
        type: 'object', additionalProperties: false,
        required: ['mutationId', 'baseRevision'],
        properties: { mutationId: uuid, baseRevision: positiveRevision },
      },
      CreatePillV1: {
        type: 'object', additionalProperties: false,
        required: ['mutationId', 'name'],
        properties: {
          mutationId: uuid, id: uuid, name: { type: 'string', minLength: 1, maxLength: 100 },
          dosage: nullableText(50), notes: nullableText(500),
          color: { type: ['string', 'null'], pattern: '^#[0-9A-Fa-f]{6}$' }, lowStockThreshold: { type: ['integer', 'null'], minimum: 0 }, isPrn: { type: 'boolean', default: false },
          amountPerUse: { oneOf: [{ $ref: '#/components/schemas/AdministrationAmountV1' }, { type: 'null' }] }, packageStrength: nullableText(500), form: nullableText(500), legacyDosageReviewed: { type: 'boolean' }, stockQuantity: { $ref: '#/components/schemas/StockQuantityV1', description: 'Exact stock of a medicine counted in a unit; currentStock stays its whole part. Present only with stockUnit.' }, stockUnit: { type: 'string', minLength: 1, maxLength: 80 }, stockNeedsRecount: { const: true, description: 'Present only while a dose that could not be subtracted exactly left the count unchanged; a start or correct command clears it.' }, shape: medicationShape,
        },
      },
      UpdatePillV1: {
        type: 'object', additionalProperties: false,
        required: ['mutationId', 'baseRevision'],
        properties: {
          mutationId: uuid, baseRevision: positiveRevision, name: { type: 'string', minLength: 1, maxLength: 100 },
          dosage: nullableText(50), notes: nullableText(500), color: { type: ['string', 'null'], pattern: '^#[0-9A-Fa-f]{6}$' },
          lowStockThreshold: { type: ['integer', 'null'], minimum: 0 }, isPrn: { type: 'boolean' },
          amountPerUse: { oneOf: [{ $ref: '#/components/schemas/AdministrationAmountV1' }, { type: 'null' }] }, packageStrength: nullableText(500), form: nullableText(500), legacyDosageReviewed: { type: 'boolean' }, shape: medicationShape, ...medicationDetailsExtraProperties,
        },
      },
      CreateScheduleV1: {
        type: 'object', additionalProperties: false,
        required: ['mutationId', 'hour', 'minute', 'frequency', 'timeZone'],
        properties: {
          mutationId: uuid, id: uuid, hour: { type: 'integer', minimum: 0, maximum: 23 }, minute: { type: 'integer', minimum: 0, maximum: 59 },
          frequency: { enum: ['daily', 'weekly', 'custom', 'interval', 'prn'] }, frequencyDays: { oneOf: [{ type: 'array', items: { type: 'integer', minimum: 1, maximum: 7 } }, { type: 'null' }] },
          everyDays: { oneOf: [{ type: 'integer', minimum: 1, maximum: 36500 }, { type: 'null' }], description: 'Required with the interval frequency (every N days), forbidden otherwise.' }, anchorDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'First dose day of an interval schedule; required with the interval frequency, forbidden otherwise.' }, startDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'No dose before this local date. Not for prn.' }, endDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'No dose after this local date (not before startDate). Not for prn.' }, isActive: { type: 'boolean' }, timeZone: { type: 'string', minLength: 1, maxLength: 128, format: 'iana-time-zone' },
        },
      },
      UpdateScheduleV1: {
        type: 'object', additionalProperties: false,
        required: ['mutationId', 'baseRevision'],
        properties: {
          mutationId: uuid, baseRevision: positiveRevision, hour: { type: 'integer', minimum: 0, maximum: 23 }, minute: { type: 'integer', minimum: 0, maximum: 59 },
          frequency: { enum: ['daily', 'weekly', 'custom', 'interval', 'prn'] }, frequencyDays: { oneOf: [{ type: 'array', items: { type: 'integer', minimum: 1, maximum: 7 } }, { type: 'null' }] },
          everyDays: { oneOf: [{ type: 'integer', minimum: 1, maximum: 36500 }, { type: 'null' }], description: 'Required with the interval frequency (every N days), forbidden otherwise.' }, anchorDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'First dose day of an interval schedule; required with the interval frequency, forbidden otherwise.' }, startDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'No dose before this local date. Not for prn.' }, endDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'No dose after this local date (not before startDate). Not for prn.' }, isActive: { type: 'boolean' }, timeZone: { type: 'string', minLength: 1, maxLength: 128, format: 'iana-time-zone' },
        },
      },
      ScheduleRepairRequest: {
        type: 'object', additionalProperties: false,
        required: ['mutationId', 'baseRevision', 'effectiveFromLocalDate', 'schedule'],
        properties: {
          mutationId: uuid, baseRevision: positiveRevision,
          effectiveFromLocalDate: { type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' },
          schedule: { $ref: '#/components/schemas/ScheduleDocument' },
        },
      },
      MedicationCommandV2: {
        type: 'object', additionalProperties: false,
        description: 'Active-ledger command (medicationCommands 2 and 3). Retrying a commandId returns its permanent receipt; stale commands are rebased with a new linked command rather than mutating the original. The miss action (medicationCommands 3) records pending to missed for an exact, expected scheduled occurrence whose planned time has passed by at least one minute (the smallest delay the app allows, less a 30 second clock tolerance): it forbids targetState, reversesEventId, rebasesCommandId, actualAt and note, returns 422 MISS_NOT_ALLOWED when the occurrence is not eligible and 409 CONFLICT_STALE_UPDATE when it is no longer pending.',
        required: ['commandId', 'occurrenceId', 'occurrenceKey', 'baseVersion', 'action', 'rebasesCommandId', 'actualAt', 'actualTimeKnown', 'note'],
        properties: {
          commandId: uuid, occurrenceId: uuid, occurrenceKey: { type: 'string', minLength: 1, maxLength: 256, description: 'Stable occurrence locator, independent of schedule edits.' },
          baseVersion: { type: 'string', pattern: '^(0|[1-9][0-9]{0,18})$' },
          action: { enum: ['take', 'skip', 'undo', 'correct', 'miss'] }, targetState: { enum: ['pending', 'taken', 'skipped'], description: 'Required only for correct. missed is reachable only through the miss action.' },
          reversesEventId: uuid, rebasesCommandId: { oneOf: [uuid, { type: 'null' }] },
          actualAt: { type: ['string', 'null'], format: 'date-time' }, actualTimeKnown: { type: 'boolean' }, note: nullableText(500),
          administrationAmount: { $ref: '#/components/schemas/AdministrationAmountV1', description: 'Valid only for take and correct. Stock counted in a unit loses exactly this amount; a plain count loses one.' },
          recordedBy: { $ref: '#/components/schemas/RecordedByV1', description: 'Display name the dose was recorded under (medicationRecordedBy). Forbidden on miss; absent means unknown.' },
        },
        allOf: [{ if: { properties: { action: { const: 'correct' } } }, then: { required: ['targetState'] } },
          { if: { properties: { action: { const: 'undo' } } }, then: { required: ['reversesEventId'] } }],
      },
      StockQuantityV1: {
        type: 'string', pattern: '^-?(0|[1-9][0-9]{0,13})(\\.[0-9]{0,5}[1-9])?$',
        description: 'Exact decimal stock in its one canonical spelling: no trailing zeros, at most six fraction digits, no negative zero.',
      },
      InventoryCommandV2: {
        oneOf: [
          { type: 'object', additionalProperties: false, description: 'Send exactly one of initialStock and initialQuantity. A fractional quantity needs stockUnit; stockUnit goes with initialQuantity.', required: ['action', 'commandId', 'pillId', 'baseRevision'], properties: { action: { const: 'start' }, commandId: uuid, pillId: uuid, baseRevision: positiveRevision, initialStock: { type: 'integer' }, initialQuantity: { $ref: '#/components/schemas/StockQuantityV1' }, stockUnit: { type: 'string', minLength: 1, maxLength: 80 }, note: nullableText(500) } },
          { type: 'object', additionalProperties: false, description: 'Send exactly one of amount and refillQuantity (positive).', required: ['action', 'commandId', 'pillId', 'baseRevision'], properties: { action: { const: 'refill' }, commandId: uuid, pillId: uuid, baseRevision: positiveRevision, amount: { type: 'integer', minimum: 1 }, refillQuantity: { $ref: '#/components/schemas/StockQuantityV1' }, note: nullableText(500) } },
          { type: 'object', additionalProperties: false, description: 'Send exactly one of targetStock and targetQuantity. A fractional quantity needs stockUnit.', required: ['action', 'commandId', 'pillId', 'baseRevision'], properties: { action: { const: 'correct' }, commandId: uuid, pillId: uuid, baseRevision: positiveRevision, targetStock: { type: 'integer' }, targetQuantity: { $ref: '#/components/schemas/StockQuantityV1' }, stockUnit: { type: 'string', minLength: 1, maxLength: 80 }, note: nullableText(500) } },
        ],
      },
      MedicationBridgeCommandV1: {
        type: 'object', additionalProperties: false,
        description: 'Atomic inactive-ledger bridge mutation for a legacy dose and any corresponding inventory delta. It is rejected once the active v2 ledger is authoritative.',
        required: ['commandId', 'commandBundleId', 'transactionCorrelationId', 'pillId', 'scheduleId', 'legacyDoseId', 'allowCreate', 'scheduledAt', 'status', 'takenAt', 'observedBaseDoseFingerprint', 'observedBaseStock', 'observedBasePillRevision'],
        properties: {
          commandId: uuid, commandBundleId: uuid, transactionCorrelationId: uuid, pillId: uuid, scheduleId: uuid, legacyDoseId: uuid,
          allowCreate: { type: 'boolean' }, scheduledAt: { type: 'string', format: 'date-time' },
          status: { enum: ['taken', 'missed', 'skipped', 'pending'], description: 'pending soft-deletes the dose (undo); advertised by the bridgeUndo capability.' }, takenAt: { type: ['string', 'null'], format: 'date-time' },
          note: nullableText(500), observedBaseDoseFingerprint: { type: ['string', 'null'], pattern: '^[a-f0-9]{64}$' },
          observedBaseStock: { type: ['integer', 'null'] }, observedBasePillRevision: { oneOf: [positiveRevision, { type: 'null' }] },
        },
      },
      RecordedByV1: {
        type: 'object', additionalProperties: false, required: ['version', 'name'],
        description: 'Name snapshot of who recorded a dose. Display-only: it identifies no account or device. name is null when a person recorded it but no name was resolved.',
        properties: { version: { const: 1 }, name: { type: ['string', 'null'], minLength: 1, maxLength: 100, description: 'Trimmed.' } },
      },
      AdministrationAmountV1: {
        oneOf: [
          { type: 'object', additionalProperties: false, required: ['version', 'state'], properties: { version: { const: 1 }, state: { const: 'unknown' } } },
          { type: 'object', additionalProperties: false, required: ['version', 'state', 'quantity', 'unit'], properties: {
            version: { const: 1 }, state: { const: 'known' }, quantity: { type: 'string', minLength: 1, maxLength: 64 }, unit: { type: 'string', minLength: 1, maxLength: 80 },
          } },
        ],
      },
      BridgePrnCommandV1: {
        description: 'Inactive-ledger PRN take/undo. It creates no inventory event and never converts an administration amount into stock.',
        oneOf: [
          { type: 'object', additionalProperties: false,
            required: ['operation', 'commandId', 'eventId', 'occurrenceId', 'occurrenceKey', 'profileId', 'pillId', 'scheduleId', 'scheduleRevision', 'plannedLocalDate', 'timeZone', 'actualAt', 'actualTimeKnown', 'amount', 'note'],
            properties: {
              operation: { const: 'take' }, commandId: uuid, eventId: uuid, occurrenceId: uuid,
              occurrenceKey: { type: 'string', pattern: '^prn:v1:[0-9a-fA-F-]{36}$', maxLength: 256 },
              profileId: uuid, pillId: uuid, scheduleId: uuid, scheduleRevision: positiveRevision,
              plannedLocalDate: { type: 'string', format: 'date' }, timeZone: { type: 'string', minLength: 1, maxLength: 128, format: 'iana-time-zone' },
              actualAt: { type: ['string', 'null'], format: 'date-time' }, actualTimeKnown: { type: 'boolean' },
              amount: { $ref: '#/components/schemas/AdministrationAmountV1' }, note: nullableText(500),
              recordedBy: { $ref: '#/components/schemas/RecordedByV1' },
            },
          },
          { type: 'object', additionalProperties: false,
            required: ['operation', 'commandId', 'eventId', 'occurrenceId', 'occurrenceKey', 'baseVersion', 'reversesEventId', 'note'],
            properties: {
              operation: { const: 'undo' }, commandId: uuid, eventId: uuid, occurrenceId: uuid,
              occurrenceKey: { type: 'string', pattern: '^prn:v1:[0-9a-fA-F-]{36}$', maxLength: 256 },
              baseVersion: positiveRevision, reversesEventId: uuid, note: nullableText(500),
              recordedBy: { $ref: '#/components/schemas/RecordedByV1' },
            },
          },
        ],
      },
      MedicationBridgeSyncSnapshotV1: {
        type: 'object', additionalProperties: false, readOnly: true,
        description: 'Finite read-only bridge snapshot. It never authorizes a write and is reconciled through the permanent checkpoint endpoint before active-ledger v2 writes.',
        required: ['contractVersion', 'afterSequence', 'throughSequence', 'items', 'nextCursor'],
        properties: {
          contractVersion: { const: 1 },
          afterSequence: { type: 'string', pattern: '^(0|[1-9][0-9]*)$' },
          throughSequence: { type: 'string', pattern: '^(0|[1-9][0-9]*)$' },
          items: { type: 'array', items: { oneOf: [
            { $ref: '#/components/schemas/MedicationSyncComponentV2' },
            { $ref: '#/components/schemas/IdentityMappingItemV2' },
          ] } },
          nextCursor: { type: ['string', 'null'] },
        },
      },
      MedicationLocatorV2: {
        type: 'object', additionalProperties: false, readOnly: true,
        required: ['occurrenceId', 'occurrenceKey', 'scheduleId', 'plannedLocalDate'],
        properties: {
          occurrenceId: uuid, occurrenceKey: { type: 'string', minLength: 1, maxLength: 256 },
          scheduleId: uuid, plannedLocalDate: { type: 'string', format: 'date' },
        },
      },
      LegacySplitCheckpointV1: {
        type: 'object', additionalProperties: false,
        properties: {
          operation: { enum: ['record', 'resolve'] }, issueId: uuid, commandId: uuid, commandBundleId: uuid, transactionCorrelationId: uuid,
          checkpoint: { type: 'object', additionalProperties: false, required: ['version', 'reason', 'legacySourceKind', 'legacySourceId', 'sourceFingerprint', 'observedBaseRevision', 'observedBaseStock', 'targetStock'], properties: {
            version: { const: 1 }, reason: { enum: ['source_missing', 'base_changed', 'evidence_ambiguous', 'evidence_conflict'] },
            legacySourceKind: { enum: ['dose_log', 'pill_stock', null] }, legacySourceId: { oneOf: [uuid, { type: 'null' }] },
            sourceFingerprint: { type: ['string', 'null'], pattern: '^[a-f0-9]{64}$' }, observedBaseRevision: { oneOf: [positiveRevision, { type: 'null' }] },
            observedBaseStock: { type: ['integer', 'null'] }, targetStock: { type: ['integer', 'null'] },
          } },
          baseIssueRevision: positiveRevision, resolution: { enum: ['adopt', 'apply_residual', 'keep_server_state'] },
        },
        oneOf: [
          { required: ['operation', 'issueId', 'commandId', 'commandBundleId', 'transactionCorrelationId', 'checkpoint'] },
          { required: ['operation', 'issueId', 'commandId', 'commandBundleId', 'transactionCorrelationId', 'baseIssueRevision', 'resolution'] },
        ],
      },
      MovedHistoryRequestV1: {
        type: 'object', additionalProperties: false,
        required: ['scheduleId', 'items'],
        properties: {
          scheduleId: uuid,
          items: {
            type: 'array', minItems: 1, maxItems: 200,
            items: {
              type: 'object', additionalProperties: false,
              required: ['occurrenceId', 'plannedLocalDate', 'plannedLocalTime', 'timeZone', 'routine'],
              properties: {
                occurrenceId: uuid,
                plannedLocalDate: { type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' },
                plannedLocalTime: { type: 'string', pattern: '^([01]\\d|2[0-3]):[0-5]\\d$' },
                timeZone: { type: 'string', minLength: 1, maxLength: 128, format: 'iana-time-zone' },
                routine: {
                  type: 'object', additionalProperties: false, required: ['frequency'],
                  description: 'The shape the dose was planned under; it feeds only the occurrence snapshot. Validated like a schedule document, without prn.',
                  properties: { frequency: { enum: ['daily', 'weekly', 'custom', 'interval'] }, frequencyDays: { oneOf: [{ type: 'array', maxItems: 7, items: { type: 'integer', minimum: 1, maximum: 7 } }, { type: 'null' }] }, everyDays: { oneOf: [{ type: 'integer', minimum: 1, maximum: 36500 }, { type: 'null' }], description: 'Required with the interval frequency (every N days), forbidden otherwise.' }, anchorDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'First dose day of an interval schedule; required with the interval frequency, forbidden otherwise.' }, startDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'No dose before this local date. Not for prn.' }, endDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'No dose after this local date (not before startDate). Not for prn.' } },
                },
              },
            },
          },
        },
      },
      MovedHistoryResult: {
        type: 'object', additionalProperties: false, required: ['items'],
        properties: {
          items: {
            type: 'array',
            items: {
              type: 'object', additionalProperties: false,
              required: ['occurrenceId', 'occurrenceKey', 'stateVersion', 'created'],
              properties: {
                occurrenceId: uuid, occurrenceKey: { type: 'string', minLength: 1, maxLength: 256 },
                stateVersion: { type: 'string', pattern: '^(0|[1-9][0-9]{0,18})$' }, created: { type: 'boolean' },
              },
            },
          },
        },
      },
      MedicationCommandResult: AnyJsonObject,
      InventoryCommandResult: AnyJsonObject,
      MedicationBridgeCommandResult: AnyJsonObject,
      LegacySplitReconciliationResult: AnyJsonObject,
      IdentityMappingItemV2: {
        type: 'object', additionalProperties: false,
        required: ['kind', 'mappingRevision', 'legacySourceKind', 'legacySourceId', 'historyId', 'bridgeCommandId', 'targetEntityType', 'targetEntityId', 'targetRevision'],
        properties: {
          kind: { const: 'identityMapping' }, mappingRevision: positiveRevision,
          legacySourceKind: { enum: ['dose_log', 'pill_stock'] }, legacySourceId: uuid,
          historyId: { oneOf: [uuid, { type: 'null' }] }, bridgeCommandId: { oneOf: [uuid, { type: 'null' }] },
          targetEntityType: { enum: ['medication_occurrence', 'occurrence_event', 'inventory_event', 'legacy_medication_history'] },
          targetEntityId: uuid, targetRevision: positiveRevision,
        },
      },
      MedicationSyncComponentV2: {
        type: 'object', additionalProperties: false,
        required: ['component', 'contractVersion', 'afterSequence', 'throughSequence', 'items', 'nextCursor'],
        properties: {
          component: { enum: ['account', 'stable', 'medicationBridge', 'medication'] }, contractVersion: { type: 'integer' },
          afterSequence: { type: 'string', pattern: '^(0|[1-9][0-9]*)$' }, throughSequence: { type: 'string', pattern: '^(0|[1-9][0-9]*)$' },
          items: { type: 'array', items: AnyJsonObject }, nextCursor: { type: ['string', 'null'] },
        },
      },
      AccountSettingKeyV1: {
        type: 'string', maxLength: 128,
        pattern: '^(reminders\\.snoozeMinutes|reminders\\.(routine|person)\\.[0-9a-f-]{36}|recordedBy|asNeeded\\.inStats|medications\\.siblingDetection|today\\.noticesLater|appearance\\.(text|colors)|language)$',
        description: 'Allowlisted setting key. Each key has its own strict value schema, listed in contracts/account-settings-v1.json. An unknown key is refused with SETTINGS_KEY_UNKNOWN.',
      },
      AccountSettingsPageV1: {
        type: 'object', additionalProperties: false, required: ['revision', 'items', 'hasMore'],
        properties: {
          revision: { type: 'integer', minimum: 0, description: 'The account head revision: the newest revision any key holds.' },
          items: { type: 'array', maxItems: 500, items: {
            type: 'object', additionalProperties: false, required: ['key', 'value', 'revision', 'updatedAt'],
            properties: { key: { $ref: '#/components/schemas/AccountSettingKeyV1' }, value: { description: 'null is a cleared key (tombstone).' }, revision: { type: 'integer', minimum: 1 }, updatedAt: { type: 'string', format: 'date-time' } },
          } },
          hasMore: { type: 'boolean', description: 'Continue with afterRevision set to the last item revision.' },
        },
      },
      AccountSettingsPutRequestV1: {
        type: 'object', additionalProperties: false, required: ['changes'],
        properties: { changes: { type: 'array', minItems: 1, maxItems: 100, items: {
          type: 'object', additionalProperties: false, required: ['key', 'value', 'baseRevision'],
          properties: {
            key: { $ref: '#/components/schemas/AccountSettingKeyV1' }, value: { description: 'The new value, or null to clear the key. At most 8192 bytes of JSON.' },
            baseRevision: { type: 'integer', minimum: 0, description: 'The revision this device last saw for the key; 0 when it has none.' },
            ifAbsent: { type: 'boolean', description: 'Seed only: keep whatever the account already holds, including a cleared key.' },
          },
        } } },
      },
      AccountSummaryV1: {
        type: 'object', additionalProperties: false, required: ['email', 'twoFactorEnabled', 'counts'],
        properties: {
          email: { type: 'string' },
          twoFactorEnabled: { type: 'boolean' },
          counts: { type: 'object', additionalProperties: false,
            required: ['people', 'medications', 'routines', 'doses', 'inventoryEvents', 'devices', 'settings'],
            properties: {
              people: { type: 'integer', minimum: 0 }, medications: { type: 'integer', minimum: 0 },
              routines: { type: 'integer', minimum: 0 }, doses: { type: 'integer', minimum: 0 },
              inventoryEvents: { type: 'integer', minimum: 0 }, devices: { type: 'integer', minimum: 0 },
              settings: { type: 'integer', minimum: 0 },
            } },
        },
      },
      AccountExportV1: {
        type: 'object', additionalProperties: false, required: ['format', 'version', 'exportedAt', 'account', 'tables'],
        description: 'One JSON document. Each table is an array of rows with camelCase top-level keys. Secrets (password and 2FA hashes, API keys, refresh and reset tokens) are never included. Contract: contracts/account-self-service-v1.json.',
        properties: {
          format: { const: 'simpastil-account-export' }, version: { const: 1 },
          exportedAt: { type: 'string', format: 'date-time' },
          account: { type: 'object', additionalProperties: false, required: ['id', 'email', 'createdAt', 'twoFactorEnabled'],
            properties: { id: uuid, email: { type: 'string' }, createdAt: { type: 'string', format: 'date-time' }, twoFactorEnabled: { type: 'boolean' } } },
          tables: { type: 'object', additionalProperties: { type: 'array', items: AnyJsonObject } },
        },
      },
      AccountDeleteRequestV1: {
        type: 'object', additionalProperties: false, required: ['password'],
        properties: { password: { type: 'string', minLength: 1, maxLength: 1024 }, code: { type: 'string', minLength: 1, maxLength: 64, description: 'Required when two-factor authentication is on (TOTP_REQUIRED otherwise). A backup code also works.' } },
      },
      ChangeEmailRequestV1: {
        type: 'object', additionalProperties: false, required: ['password', 'newEmail'],
        properties: {
          password: { type: 'string', minLength: 1, maxLength: 1024 },
          code: { type: 'string', minLength: 1, maxLength: 64, description: 'Required when two-factor authentication is on.' },
          newEmail: { type: 'string', maxLength: 320, format: 'email', description: 'Trimmed and lower-cased by the server. AUTH_EMAIL_TAKEN (409) when another account uses it.' },
        },
      },
      ChangeEmailResponseV1: {
        type: 'object', additionalProperties: false, required: ['status'],
        properties: { status: { enum: ['changed', 'confirmationSent'], description: 'changed: the email is already the new one. confirmationSent: a link went to the new address and a notice to the old one; nothing changes until the link is opened. Every sign-in stays valid either way.' } },
      },
      ConfirmEmailChangeRequestV1: {
        type: 'object', additionalProperties: false, required: ['token'],
        properties: { token: { type: 'string', minLength: 32, maxLength: 512 } },
      },
      AccountSettingsPutResponseV1: {
        type: 'object', additionalProperties: false, required: ['revision', 'results'],
        properties: { revision: { type: 'integer', minimum: 0 }, results: { type: 'array', items: { oneOf: [
          { type: 'object', additionalProperties: false, required: ['key', 'status', 'revision'], properties: { key: { $ref: '#/components/schemas/AccountSettingKeyV1' }, status: { const: 'applied' }, revision: { type: 'integer', minimum: 1 } } },
          { type: 'object', additionalProperties: false, required: ['key', 'status', 'current'], properties: { key: { $ref: '#/components/schemas/AccountSettingKeyV1' }, status: { enum: ['kept', 'conflict'] }, current: { type: 'object', additionalProperties: false, required: ['value', 'revision'], properties: { value: {}, revision: { type: 'integer', minimum: 0 } } } } },
        ] } } },
      },
      ComponentSyncResponseV2: {
        type: 'object', additionalProperties: false,
        required: ['component', 'contractVersion', 'afterSequence', 'throughSequence', 'items', 'nextCursor', 'hasMore'],
        properties: {
          component: { enum: ['account', 'stable', 'medicationBridge', 'medication'] },
          contractVersion: { type: 'integer', enum: [1, 2, 3, 4, 5] },
          afterSequence: { type: 'string', pattern: '^(0|[1-9][0-9]{0,18})$' },
          throughSequence: { type: 'string', pattern: '^(0|[1-9][0-9]{0,18})$' },
          items: { type: 'array', items: {
            type: 'object', additionalProperties: false,
            required: ['serverSequence', 'change'],
            properties: {
              serverSequence: { type: 'string', pattern: '^(0|[1-9][0-9]{0,18})$' },
              change: { $ref: '#/components/schemas/SyncChangePayloadV2' },
            },
          } },
          nextCursor: { type: ['string', 'null'], maxLength: 4096 },
          hasMore: { type: 'boolean' },
        },
      },
      SyncChangePayloadV2: {
        type: 'object', additionalProperties: false,
        required: ['schemaVersion', 'component', 'entityType', 'entityId', 'operation', 'sourceIdentity', 'payload'],
        properties: {
          schemaVersion: { const: 2 }, component: { enum: ['account', 'stable', 'medicationBridge', 'medication'] },
          entityType: { enum: ['account', 'migration_issue', 'profile', 'pill', 'schedule', 'bridge_dose', 'bridge_stock', 'medication_occurrence', 'occurrence_event', 'inventory_event', 'legacy_medication_history', 'identity_mapping'] },
          entityId: uuid, operation: { enum: ['upsert', 'tombstone', 'mapping'] },
          sourceIdentity: { type: 'object', additionalProperties: false, required: ['sourceKind', 'sourceId', 'sourceRevision'], properties: {
            sourceKind: { enum: ['account', 'migration_issue', 'profile', 'pill', 'schedule', 'legacy_dose_log', 'legacy_pill_stock', 'legacy_history_entry', 'occurrence', 'occurrence_event', 'inventory_event', 'bridge_mapping'] },
            sourceId: uuid, sourceRevision: positiveRevision,
          } },
          payload: { oneOf: [
            'AccountSyncItemV2', 'MigrationIssueSyncItemV2', 'ProfileSyncItemV2', 'PillSyncItemV2', 'ScheduleSyncItemV2',
            'BridgeDoseSyncItemV1', 'BridgeStockSyncItemV1', 'MedicationOccurrenceSyncItemV2', 'OccurrenceEventSyncItemV2',
            'InventoryEventSyncItemV2', 'LegacyEstimatedHistoryV1', 'TombstoneSyncItemV2', 'IdentityMappingItemV2',
          ].map((name) => ({ $ref: `#/components/schemas/${name}` })) },
        },
      },
      AccountSyncItemV2: {
        type: 'object', additionalProperties: false, required: ['kind', 'id', 'email', 'revision', 'createdAt', 'updatedAt'],
        properties: { kind: { const: 'account' }, id: uuid, email: { type: 'string', format: 'email' }, revision: positiveRevision, createdAt: { type: 'string', format: 'date-time' }, updatedAt: { type: 'string', format: 'date-time' } },
      },
      MigrationIssueSyncItemV2: {
        type: 'object', additionalProperties: false, required: ['kind', 'id', 'entityType', 'entityId', 'issueCode', 'safeSnapshot', 'revision', 'state', 'resolvedAt', 'createdAt'],
        properties: { kind: { const: 'migrationIssue' }, id: uuid, entityType: { type: 'string', pattern: '^[a-z][a-z0-9_]{0,31}$' }, entityId: uuid, issueCode: { type: 'string', pattern: '^[a-z][a-z0-9_]{0,63}$' }, safeSnapshot: AnyJsonObject, revision: positiveRevision, state: { enum: ['unresolved', 'resolved'] }, resolvedAt: { type: ['string', 'null'], format: 'date-time' }, createdAt: { type: 'string', format: 'date-time' } },
      },
      ProfileSyncItemV2: {
        type: 'object', additionalProperties: false, required: ['kind', 'id', 'userId', 'name', 'avatarEmoji', 'isActive', 'revision', 'deletedAt', 'createdAt', 'updatedAt'],
        properties: { kind: { const: 'profile' }, id: uuid, userId: uuid, name: { type: 'string', minLength: 1, maxLength: 100 }, avatarEmoji: { type: 'string', minLength: 1, maxLength: 32 }, isActive: { type: 'boolean' }, revision: positiveRevision, deletedAt: { type: ['string', 'null'], format: 'date-time' }, createdAt: { type: 'string', format: 'date-time' }, updatedAt: { type: 'string', format: 'date-time' } },
      },
      PillPhotoV1: {
        type: 'object', additionalProperties: false, required: ['pillId', 'sha256', 'revision', 'width', 'height', 'pillRevision'],
        properties: { pillId: uuid, sha256: { type: 'string', pattern: '^[0-9a-f]{64}$' }, revision: positiveRevision, width: { type: 'integer', minimum: 1, maximum: 1600 }, height: { type: 'integer', minimum: 1, maximum: 1600 }, pillRevision: { ...positiveRevision, description: 'The revision of the medication after this write; a photo change advances it by one.' } },
      },
      PillPhotoRefV1: {
        type: 'object', additionalProperties: false, required: ['sha256', 'revision'],
        properties: { sha256: { type: 'string', pattern: '^[0-9a-f]{64}$' }, revision: positiveRevision },
      },
      PillSyncItemV2: {
        type: 'object', additionalProperties: false, required: ['kind', 'id', 'profileId', 'name', 'dosage', 'notes', 'color', 'currentStock', 'lowStockThreshold', 'isPrn', 'revision', 'deletedAt', 'createdAt', 'updatedAt'],
        properties: { kind: { const: 'pill' }, id: uuid, profileId: uuid, name: { type: 'string', minLength: 1, maxLength: 100 }, dosage: nullableText(50), notes: nullableText(500), color: { type: ['string', 'null'], pattern: '^#[0-9A-Fa-f]{6}$' }, currentStock: { type: ['integer', 'null'] }, lowStockThreshold: { type: ['integer', 'null'], minimum: 0 }, isPrn: { type: 'boolean' }, amountPerUse: { oneOf: [{ $ref: '#/components/schemas/AdministrationAmountV1' }, { type: 'null' }] }, packageStrength: nullableText(500), form: nullableText(500), legacyDosageReviewed: { type: 'boolean' }, shape: { type: ['string', 'null'], minLength: 1, maxLength: 32 }, ...medicationDetailsExtraProperties, photo: { $ref: '#/components/schemas/PillPhotoRefV1' }, revision: positiveRevision, deletedAt: { type: ['string', 'null'], format: 'date-time' }, createdAt: { type: 'string', format: 'date-time' }, updatedAt: { type: 'string', format: 'date-time' } },
      },
      ScheduleSyncItemV2: {
        type: 'object', additionalProperties: false, required: ['kind', 'id', 'pillId', 'hour', 'minute', 'frequency', 'frequencyDays', 'isActive', 'revision', 'timeZoneStatus', 'timeZone', 'deletedAt', 'createdAt', 'updatedAt'],
        properties: { kind: { const: 'schedule' }, id: uuid, pillId: uuid, hour: { type: 'integer', minimum: 0, maximum: 23 }, minute: { type: 'integer', minimum: 0, maximum: 59 }, frequency: { enum: ['daily', 'weekly', 'custom', 'interval', 'prn'] }, frequencyDays: { oneOf: [{ type: 'array', maxItems: 7, items: { type: 'integer', minimum: 1, maximum: 7 } }, { type: 'null' }] }, everyDays: { oneOf: [{ type: 'integer', minimum: 1, maximum: 36500 }, { type: 'null' }], description: 'Required with the interval frequency (every N days), forbidden otherwise.' }, anchorDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'First dose day of an interval schedule; required with the interval frequency, forbidden otherwise.' }, startDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'No dose before this local date. Not for prn.' }, endDate: { oneOf: [{ type: 'string', format: 'date', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, { type: 'null' }], description: 'No dose after this local date (not before startDate). Not for prn.' }, isActive: { type: 'boolean' }, revision: positiveRevision, timeZoneStatus: { enum: ['known', 'legacy_unknown'] }, timeZone: { type: ['string', 'null'], maxLength: 128, format: 'iana-time-zone' }, deletedAt: { type: ['string', 'null'], format: 'date-time' }, createdAt: { type: 'string', format: 'date-time' }, updatedAt: { type: 'string', format: 'date-time' } },
      },
      BridgeDoseSyncItemV1: {
        type: 'object', additionalProperties: false, required: ['kind', 'id', 'scheduleId', 'scheduledAt', 'takenAt', 'status', 'deletedAt', 'sourceRevision'],
        properties: { kind: { const: 'bridgeDose' }, id: uuid, scheduleId: uuid, scheduledAt: { type: 'string', format: 'date-time' }, takenAt: { type: ['string', 'null'], format: 'date-time' }, status: { enum: ['taken', 'missed', 'skipped'] }, deletedAt: { type: ['string', 'null'], format: 'date-time' }, sourceRevision: positiveRevision,
          parentSchedule: { $ref: '#/components/schemas/HistoricalParentScheduleV2', description: 'Response-only historical parent for bridge v2/v3. In v3 all three ancestor snapshots are present together or absent together.' },
          parentPill: { $ref: '#/components/schemas/PillSyncItemV2', description: 'Response-only complete canonical medication for bridge v3, including deleted ancestors.' },
          parentProfile: { $ref: '#/components/schemas/ProfileSyncItemV2', description: 'Response-only complete canonical person for bridge v3, verified to the authenticated owner.' },
        },
      },
      HistoricalParentScheduleV2: {
        type: 'object', additionalProperties: false,
        required: ['id', 'pillId', 'hour', 'minute', 'frequency', 'frequencyDays', 'revision', 'createdAt', 'updatedAt', 'deletedAt', 'disposition'],
        properties: {
          id: uuid, pillId: uuid, hour: { type: 'integer', minimum: 0, maximum: 23 }, minute: { type: 'integer', minimum: 0, maximum: 59 },
          frequency: { enum: ['daily', 'weekly', 'custom', 'interval', 'prn'] },
          frequencyDays: { oneOf: [{ type: 'array', maxItems: 4096, items: { type: ['integer', 'null'], minimum: -2147483648, maximum: 2147483647 } }, { type: 'null' }] },
          revision: positiveRevision, createdAt: { type: 'string', format: 'date-time' }, updatedAt: { type: 'string', format: 'date-time' },
          deletedAt: { type: ['string', 'null'], format: 'date-time' }, disposition: { enum: ['quarantined', 'deleted'] },
        },
      },
      BridgeStockSyncItemV1: {
        type: 'object', additionalProperties: false, required: ['kind', 'pillId', 'currentStock', 'sourceRevision', 'updatedAt'],
        properties: { kind: { const: 'bridgeStock' }, pillId: uuid, currentStock: { type: ['integer', 'null'] }, sourceRevision: positiveRevision, updatedAt: { type: 'string', format: 'date-time' } },
      },
      MedicationOccurrenceSyncItemV2: {
        type: 'object', additionalProperties: false, required: ['kind', 'id', 'pillId', 'scheduleId', 'occurrenceKey', 'source', 'scheduleRevision', 'plannedLocalDate', 'plannedLocalTime', 'timeZone', 'plannedAt', 'expected', 'snapshotVersion', 'scheduleSnapshot', 'provenance', 'supersededAt', 'supersededByOccurrenceId', 'stateVersion'],
        properties: { kind: { const: 'medicationOccurrence' }, id: uuid, pillId: { oneOf: [uuid, { type: 'null' }] }, scheduleId: { oneOf: [uuid, { type: 'null' }] }, occurrenceKey: { type: 'string', minLength: 1, maxLength: 256 }, source: { enum: ['scheduled', 'prn', 'legacy'] }, scheduleRevision: { oneOf: [positiveRevision, { type: 'null' }] }, plannedLocalDate: { type: 'string', format: 'date' }, plannedLocalTime: { type: ['string', 'null'] }, timeZone: { type: 'string', maxLength: 128 }, plannedAt: { type: ['string', 'null'], format: 'date-time' }, expected: { type: 'boolean' }, snapshotVersion: { enum: [1, 3], description: 'Snapshot 1 is the original shape; 3 adds everyDays, anchorDate, startDate and endDate (interval or dated routines).' }, scheduleSnapshot: AnyJsonObject, provenance: { enum: ['exact', 'legacy_estimated'] }, supersededAt: { type: ['string', 'null'], format: 'date-time' }, supersededByOccurrenceId: { oneOf: [uuid, { type: 'null' }] }, stateVersion: { type: 'string', pattern: '^(0|[1-9][0-9]{0,18})$' } },
      },
      OccurrenceEventSyncItemV2: {
        type: 'object', additionalProperties: false, required: ['kind', 'id', 'occurrenceId', 'commandId', 'action', 'fromState', 'toState', 'reversesEventId', 'rebasesCommandId', 'actualAt', 'actualTimeKnown', 'administrationAmount', 'note', 'origin', 'baseVersion', 'resultVersion', 'serverSequence', 'recordedAt'],
        properties: { kind: { const: 'occurrenceEvent' }, id: uuid, occurrenceId: uuid, commandId: uuid, action: { enum: ['take', 'skip', 'undo', 'correct', 'miss'] }, fromState: { enum: ['pending', 'taken', 'skipped', 'missed'] }, toState: { enum: ['pending', 'taken', 'skipped', 'missed'] }, reversesEventId: { oneOf: [uuid, { type: 'null' }] }, rebasesCommandId: { oneOf: [uuid, { type: 'null' }] }, actualAt: { type: ['string', 'null'], format: 'date-time' }, actualTimeKnown: { type: 'boolean' }, administrationAmount: { oneOf: [{ $ref: '#/components/schemas/AdministrationAmountV1' }, { type: 'null' }] }, recordedBy: { $ref: '#/components/schemas/RecordedByV1' }, note: nullableText(500), origin: { enum: ['native', 'legacy_backfill', 'legacy_handoff'] }, baseVersion: { type: 'string', pattern: '^(0|[1-9][0-9]{0,18})$' }, resultVersion: positiveRevision, serverSequence: positiveRevision, recordedAt: { type: 'string', format: 'date-time' } },
      },
      InventoryEventSyncItemV2: {
        type: 'object', additionalProperties: false, required: ['kind', 'id', 'pillId', 'commandId', 'eventKind', 'occurrenceEventId', 'reversesInventoryEventId', 'provenance', 'note', 'serverSequence', 'recordedAt'],
        properties: { kind: { const: 'inventoryEvent' }, id: uuid, pillId: uuid, commandId: uuid, eventKind: { enum: ['opening', 'dose', 'dose_reversal', 'refill', 'correction'] }, delta: { type: 'integer' }, quantityDelta: { $ref: '#/components/schemas/StockQuantityV1' }, occurrenceEventId: { oneOf: [uuid, { type: 'null' }] }, reversesInventoryEventId: { oneOf: [uuid, { type: 'null' }] }, provenance: { enum: ['native', 'legacy_backfill', 'legacy_handoff'] }, note: nullableText(500), serverSequence: positiveRevision, recordedAt: { type: 'string', format: 'date-time' } },
      },
      LegacyEstimatedHistoryV1: {
        type: 'object', additionalProperties: false, required: ['kind', 'version', 'historyId', 'historyEntryId', 'sourceRevision', 'operation', 'legacySourceKind', 'legacySourceId', 'pillId', 'scheduleId', 'localDateEvidence', 'localTimeEvidence', 'storedUtc', 'timeZoneStatus', 'provenance', 'state', 'historicalInventoryDeltaEvidence', 'inventoryDeltaProvenance', 'migrationInventoryEffect', 'inventoryDisposition', 'sourceFingerprint', 'entityRevision'],
        properties: { kind: { const: 'legacyEstimatedHistory' }, version: { const: 1 }, historyId: uuid, historyEntryId: uuid, sourceRevision: positiveRevision, operation: { enum: ['upsert', 'tombstone'] }, legacySourceKind: { enum: ['dose_log', 'pill_stock'] }, legacySourceId: uuid, pillId: { oneOf: [uuid, { type: 'null' }] }, scheduleId: { oneOf: [uuid, { type: 'null' }] }, localDateEvidence: { type: ['string', 'null'], format: 'date' }, localTimeEvidence: { type: ['string', 'null'] }, storedUtc: { type: ['string', 'null'], format: 'date-time' }, timeZoneStatus: { const: 'legacy_unknown' }, provenance: { const: 'legacy_estimated' }, state: { enum: ['taken', 'missed', 'skipped', null] }, historicalInventoryDeltaEvidence: { type: ['string', 'null'], pattern: '^-?(0|[1-9][0-9]{0,18})$' }, inventoryDeltaProvenance: { enum: ['explicit_source', 'linked_command', 'unknown'] }, migrationInventoryEffect: { const: 'none' }, inventoryDisposition: { enum: ['evidence_only', 'effect_unknown'] }, sourceFingerprint: { type: 'string', pattern: '^[a-f0-9]{64}$' }, entityRevision: positiveRevision },
      },
      TombstoneSyncItemV2: {
        type: 'object', additionalProperties: false, required: ['kind', 'entityType', 'id', 'revision', 'deletedAt'],
        properties: { kind: { const: 'tombstone' }, entityType: { enum: ['account', 'migration_issue', 'profile', 'pill', 'schedule', 'bridge_dose', 'bridge_stock', 'medication_occurrence', 'occurrence_event', 'inventory_event', 'legacy_medication_history'] }, id: uuid, revision: positiveRevision, deletedAt: { type: 'string', format: 'date-time' } },
      },
    },
  },
} as const;

export const openApiRouteInventory = routes.map(({ method, path, operationId }) => ({ method, path, operationId }));
