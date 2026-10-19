import api, { apiErrorMessage } from './api'

export interface TwoFactorStatus {
  available: boolean
  enabled: boolean
  backupCodesRemaining: number
}

export interface TwoFactorSetup {
  secret: string
  otpauthUri: string
}

export type TwoFactorResult<T> = { ok: true; value: T } | { ok: false; error: string }

async function call<T>(request: Promise<Response>, read: (res: Response) => Promise<T>): Promise<TwoFactorResult<T>> {
  try {
    const res = await request
    if (!res.ok) return { ok: false, error: await apiErrorMessage(res) }
    return { ok: true, value: await read(res) }
  } catch {
    return { ok: false, error: 'Network error' }
  }
}

export function loadStatus(): Promise<TwoFactorResult<TwoFactorStatus>> {
  return call(api.get('/admin/auth/2fa/status'), (res) => res.json() as Promise<TwoFactorStatus>)
}

export function startSetup(): Promise<TwoFactorResult<TwoFactorSetup>> {
  return call(api.post('/admin/auth/2fa/setup', {}), (res) => res.json() as Promise<TwoFactorSetup>)
}

/** Confirms the first code. Returns the backup codes, which exist only in this reply. */
export function confirmSetup(code: string): Promise<TwoFactorResult<string[]>> {
  return call(api.post('/admin/auth/2fa/enable', { code }), async (res) => ((await res.json()) as { backupCodes: string[] }).backupCodes)
}

export function regenerateBackupCodes(code: string): Promise<TwoFactorResult<string[]>> {
  return call(api.post('/admin/auth/2fa/backup-codes', { code }), async (res) => ((await res.json()) as { backupCodes: string[] }).backupCodes)
}

export function disableTwoFactor(code: string): Promise<TwoFactorResult<true>> {
  return call(api.post('/admin/auth/2fa/disable', { code }), async () => true as const)
}

/** Groups a secret in fours so it is easier to read aloud or type. */
export function groupSecret(secret: string): string {
  return secret.replace(/\s+/g, '').replace(/(.{4})/g, '$1 ').trim()
}

/** The text file offered for download: only the codes and where they belong. */
export function backupCodesFile(codes: string[], host: string, now = new Date()): string {
  return [
    `Simpastil admin backup codes for ${host}`,
    `Created ${now.toISOString().slice(0, 10)}`,
    '',
    'Each code works once, in place of an authenticator code.',
    'Keep this file somewhere private.',
    '',
    ...codes,
    '',
  ].join('\n')
}
