import { onMounted, ref, type Ref } from 'vue'
import api, { apiErrorMessage } from './api'

/** What the administrator picked; `null` is "automatic". */
export type ResetModeChoice = 'email' | 'manual' | null
export type ResetMode = 'email' | 'manual'

export interface ResetSettings {
  passwordResetMode: ResetModeChoice
  effectivePasswordResetMode: ResetMode
  resetLinkLifetimeMinutes: number
  smtpConfigured: boolean
}

export const MIN_LIFETIME_MINUTES = 5
export const MAX_LIFETIME_MINUTES = 24 * 60

export type LifetimeUnit = 'minutes' | 'hours'

function isChoice(value: unknown): value is ResetModeChoice {
  return value === null || value === 'email' || value === 'manual'
}

/** Reads the settings response defensively; anything unexpected counts as unavailable. */
export function parseSettings(body: unknown): ResetSettings | null {
  if (typeof body !== 'object' || body === null) return null
  const b = body as Record<string, unknown>
  const effective = b['effectivePasswordResetMode']
  const minutes = b['resetLinkLifetimeMinutes']
  if (!isChoice(b['passwordResetMode'])) return null
  if (effective !== 'email' && effective !== 'manual') return null
  if (typeof minutes !== 'number' || !Number.isInteger(minutes)) return null
  if (typeof b['smtpConfigured'] !== 'boolean') return null
  return {
    passwordResetMode: b['passwordResetMode'],
    effectivePasswordResetMode: effective,
    resetLinkLifetimeMinutes: minutes,
    smtpConfigured: b['smtpConfigured'],
  }
}

export async function loadSettings(): Promise<ResetSettings | null> {
  try {
    const res = await api.get('/admin/settings')
    if (!res.ok) return null
    return parseSettings(await res.json())
  } catch {
    return null
  }
}

/** Whole hours show as hours, anything else as minutes. */
export function splitLifetime(minutes: number): { value: number; unit: LifetimeUnit } {
  if (minutes >= 60 && minutes % 60 === 0) return { value: minutes / 60, unit: 'hours' }
  return { value: minutes, unit: 'minutes' }
}

/** The minutes for what was typed, or why it cannot be used. */
export function lifetimeToMinutes(
  raw: string,
  unit: LifetimeUnit,
): { ok: true; minutes: number } | { ok: false; error: string } {
  const text = raw.trim()
  if (!/^\d+$/.test(text)) return { ok: false, error: 'Enter a whole number.' }
  const minutes = Number(text) * (unit === 'hours' ? 60 : 1)
  if (minutes < MIN_LIFETIME_MINUTES) return { ok: false, error: 'The shortest lifetime is 5 minutes.' }
  if (minutes > MAX_LIFETIME_MINUTES) return { ok: false, error: 'The longest lifetime is 24 hours.' }
  return { ok: true, minutes }
}

/** "1 hour", "90 minutes": how a stored lifetime reads in a sentence. */
export function describeLifetime(minutes: number): string {
  const { value, unit } = splitLifetime(minutes)
  const noun = unit === 'hours' ? 'hour' : 'minute'
  return `${value} ${noun}${value === 1 ? '' : 's'}`
}

export type SaveResult = { ok: true; settings: ResetSettings } | { ok: false; error: string }

export async function saveSettings(patch: {
  passwordResetMode?: ResetModeChoice
  resetLinkLifetimeMinutes?: number
}): Promise<SaveResult> {
  try {
    const res = await api.put('/admin/settings', patch)
    if (!res.ok) return { ok: false, error: await apiErrorMessage(res) }
    const settings = parseSettings(await res.json())
    return settings ? { ok: true, settings } : { ok: false, error: 'Unexpected answer from the server' }
  } catch {
    return { ok: false, error: 'Network error' }
  }
}

export interface ResetLink {
  link: string
  expiresAt: string
}

export type ResetLinkResult = { ok: true; value: ResetLink } | { ok: false; error: string }

export async function createResetLink(userId: string): Promise<ResetLinkResult> {
  try {
    const res = await api.post(`/admin/users/${encodeURIComponent(userId)}/reset-link`, {})
    if (!res.ok) return { ok: false, error: await apiErrorMessage(res) }
    const body = await res.json() as Partial<ResetLink>
    if (typeof body.link !== 'string' || typeof body.expiresAt !== 'string') {
      return { ok: false, error: 'Unexpected answer from the server' }
    }
    return { ok: true, value: { link: body.link, expiresAt: body.expiresAt } }
  } catch {
    return { ok: false, error: 'Network error' }
  }
}

export interface EmailStatus {
  configured: boolean
  effectiveMode: ResetMode
  recentPermanentFailures: number
  lastPermanentFailureAt: string | null
}

/** The window the server counts failures over, in days. */
export const EMAIL_FAILURE_WINDOW_DAYS = 7

export function parseEmailStatus(body: unknown): EmailStatus | null {
  if (typeof body !== 'object' || body === null) return null
  const b = body as Record<string, unknown>
  const failures = b['recentPermanentFailures']
  const last = b['lastPermanentFailureAt']
  if (typeof b['configured'] !== 'boolean') return null
  if (b['effectiveMode'] !== 'email' && b['effectiveMode'] !== 'manual') return null
  if (typeof failures !== 'number' || !Number.isInteger(failures) || failures < 0) return null
  if (last !== null && (typeof last !== 'string' || Number.isNaN(Date.parse(last)))) return null
  return {
    configured: b['configured'],
    effectiveMode: b['effectiveMode'],
    recentPermanentFailures: failures,
    lastPermanentFailureAt: last,
  }
}

export async function loadEmailStatus(): Promise<EmailStatus | null> {
  try {
    const res = await api.get('/admin/email-status')
    if (!res.ok) return null
    return parseEmailStatus(await res.json())
  } catch {
    return null
  }
}

/** True once the settings say password reset is manual, which turns email invitations off. */
export function useInvitesOff(): Ref<boolean> {
  const off = ref(false)
  onMounted(async () => {
    off.value = (await loadSettings())?.effectivePasswordResetMode === 'manual'
  })
  return off
}
