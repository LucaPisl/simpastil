export interface AuditEntry {
  id: string
  actor: string
  action: string
  targetType: string
  targetId: string | null
  metadata: Record<string, unknown> | null
  ipAddress: string | null
  createdAt: string
}

export interface AuditPage {
  logs: AuditEntry[]
  hasMore: boolean
}

export const PAGE_SIZE = 25

/** What the console says for each action the server records. */
export const ACTION_LABELS: Readonly<Record<string, string>> = {
  'admin.login': 'Signed in',
  'admin.login_failed': 'Failed sign-in attempt',
  'admin.logout': 'Signed out',
  'admin.logout_all': 'Signed out everywhere',
  'admin.password_change': 'Admin password changed',
  'admin.2fa_enable': 'Two-factor turned on',
  'admin.2fa_disable': 'Two-factor turned off',
  'admin.2fa_backup_codes': 'Backup codes replaced',
  'key.create': 'API key created',
  'key.revoke': 'API key revoked',
  'key.reveal': 'API key revealed',
  'key.invite': 'Invitation queued',
  'user.delete': 'Person deleted',
  'user.reset_link': 'Password reset link created',
  'settings.update': 'Settings changed',
  'device.logout': 'Device signed out',
}

export type AuditTone = 'neutral' | 'good' | 'warn' | 'danger'

const TONES: Readonly<Record<string, AuditTone>> = {
  'admin.login': 'good',
  'admin.login_failed': 'danger',
  'admin.logout_all': 'warn',
  'admin.password_change': 'warn',
  'admin.2fa_disable': 'warn',
  'key.revoke': 'warn',
  'key.reveal': 'warn',
  'user.delete': 'danger',
  'user.reset_link': 'warn',
  'device.logout': 'warn',
}

export const FILTER_ACTIONS: ReadonlyArray<{ value: string; label: string }> = Object.entries(ACTION_LABELS)
  .map(([value, label]) => ({ value, label }))
  .sort((a, b) => a.label.localeCompare(b.label))

export function actionLabel(entry: Pick<AuditEntry, 'action' | 'metadata'>): string {
  if (entry.action === 'admin.login') {
    if (entry.metadata?.['event'] === 'initial_setup') return 'Admin account created'
    if (entry.metadata?.['via'] === '2fa') return 'Signed in with two-factor'
  }
  return ACTION_LABELS[entry.action] ?? entry.action
}

export function actionTone(action: string): AuditTone {
  return TONES[action] ?? 'neutral'
}

const RESET_MODES: Readonly<Record<string, string>> = { email: 'by email', manual: 'by a link you hand over' }

function minutes(value: number): string {
  if (value % 60 === 0 && value >= 60) return `${value / 60} h`
  return `${value} min`
}

/**
 * The few facts worth reading beside an action. Metadata is picked field by
 * field, never dumped, so a field added to the log later stays out of the
 * console until someone decides it belongs there. Values are cut short.
 */
export function entryDetails(entry: Pick<AuditEntry, 'action' | 'metadata'>): string[] {
  const meta = entry.metadata ?? {}
  const text = (v: unknown): string | null => (typeof v === 'string' && v ? v.slice(0, 120) : null)
  const out: string[] = []
  const label = text(meta['label'])
  if (label) out.push(`Label: ${label}`)
  const email = text(meta['email'])
  if (email && entry.action === 'key.invite') out.push(`Invited ${email}`)
  const mode = text(meta['passwordResetMode'])
  if (mode) out.push(`Password reset ${RESET_MODES[mode] ?? mode}`)
  const lifetime = meta['resetLinkLifetimeMinutes']
  if (typeof lifetime === 'number' && Number.isFinite(lifetime)) out.push(`Link lifetime ${minutes(lifetime)}`)
  const expires = text(meta['expiresAt'])
  if (expires && !Number.isNaN(Date.parse(expires))) out.push(`Link expires ${formatWhen(expires)}`)
  return out
}

export function formatWhen(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return d.toLocaleString(undefined, { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })
}

/** Builds the request query from the filters. Dates are whole local days, the end day included. */
export function auditQuery(
  filters: { action: string; from: string; to: string },
  page: number,
): string {
  const q = new URLSearchParams()
  q.set('limit', String(PAGE_SIZE))
  if (page > 0) q.set('offset', String(page * PAGE_SIZE))
  if (filters.action) q.set('action', filters.action)
  const from = dayStart(filters.from)
  if (from) q.set('from', from.toISOString())
  const to = dayStart(filters.to)
  if (to) {
    to.setDate(to.getDate() + 1)
    q.set('to', to.toISOString())
  }
  return q.toString()
}

/** Local midnight of a yyyy-mm-dd value, or null when it is empty or not a date. */
function dayStart(value: string): Date | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value)
  if (!match) return null
  const d = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  return Number.isNaN(d.getTime()) ? null : d
}
