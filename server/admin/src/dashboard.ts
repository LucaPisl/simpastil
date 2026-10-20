export interface DashUser {
  id: string
  email: string
  createdAt: string
}

export interface DashKey {
  id: string
  label: string
  revokedAt: string | null
  lastUsedAt?: string | null
}

export interface Overview {
  users: number
  activeKeys: number
  revokedKeys: number
  /** Share of keys still active, 0..1; 0 when there are no keys. */
  activeShare: number
  recentUsers: DashUser[]
  recentKeys: DashKey[]
  summary: string
}

const time = (iso: string | null | undefined): number => {
  const t = iso ? Date.parse(iso) : NaN
  return Number.isFinite(t) ? t : -Infinity
}

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`
}

export function summarize(users: DashUser[], keys: DashKey[], limit = 4): Overview {
  const active = keys.filter((k) => !k.revokedAt)
  const revoked = keys.length - active.length
  const recentUsers = [...users].sort((a, b) => time(b.createdAt) - time(a.createdAt)).slice(0, limit)
  // Active keys first, most recently used on top; never-used keys after used ones.
  const recentKeys = [...active].sort((a, b) => time(b.lastUsedAt) - time(a.lastUsedAt)).slice(0, limit)

  let summary: string
  if (!users.length && !keys.length) {
    summary = 'Nothing here yet. Invite the first person to get started.'
  } else {
    summary = `${plural(users.length, 'person', 'people')} and ${plural(active.length, 'active key', 'active keys')} on this server.`
  }

  return {
    users: users.length,
    activeKeys: active.length,
    revokedKeys: revoked,
    activeShare: keys.length ? active.length / keys.length : 0,
    recentUsers,
    recentKeys,
    summary,
  }
}

/** "today", "yesterday", "3 days ago", then a short date. Calm, not precise. */
export function relativeDay(iso: string | null | undefined, now: Date = new Date()): string {
  const t = time(iso)
  if (t === -Infinity) return 'never'
  const startOf = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  const days = Math.round((startOf(now) - startOf(new Date(t))) / 86_400_000)
  if (days <= 0) return 'today'
  if (days === 1) return 'yesterday'
  if (days < 7) return `${days} days ago`
  return new Date(t).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })
}

export function initial(email: string): string {
  const c = email.trim().charAt(0)
  return c ? c.toUpperCase() : '?'
}

const RELEASE_URL_PREFIX = 'https://github.com/LucaPisl/simpastil/releases/'
const VERSION_RE = /^\d+\.\d+\.\d+$/

function compareVersions(a: string, b: string): number {
  const left = a.split('.').map(Number)
  const right = b.split('.').map(Number)
  for (let i = 0; i < Math.max(left.length, right.length); i += 1) {
    const diff = (left[i] ?? 0) - (right[i] ?? 0)
    if (diff !== 0) return diff
  }
  return 0
}

/** The banner shown when GET /capabilities reports a release newer than this server. */
export function serverUpdateBanner(caps: unknown): { version: string; url: string } | null {
  if (typeof caps !== 'object' || caps === null) return null
  const { serverVersion, latestServerVersion, latestReleaseUrl } = caps as Record<string, unknown>
  if (typeof serverVersion !== 'string' || !VERSION_RE.test(serverVersion)) return null
  if (typeof latestServerVersion !== 'string' || !VERSION_RE.test(latestServerVersion)) return null
  if (typeof latestReleaseUrl !== 'string' || !latestReleaseUrl.startsWith(RELEASE_URL_PREFIX)) return null
  if (compareVersions(latestServerVersion, serverVersion) <= 0) return null
  return { version: latestServerVersion, url: latestReleaseUrl }
}

export interface ServerInfo {
  version: string
  /** The deployment manifest's release id, a label for this deployment (for example migration-0027), not the applied database schema. */
  release: string | null
  update: { state: 'available'; latest: string } | { state: 'current'; latest: string } | { state: 'unknown' }
}

/**
 * What GET /capabilities says about the server itself. Nothing is inferred:
 * with no `latestServerVersion` the update check has either not answered yet
 * or is switched off, and the console cannot tell which, so it says neither.
 */
export function serverInfo(caps: unknown): ServerInfo | null {
  if (typeof caps !== 'object' || caps === null) return null
  const { serverVersion, serverRelease, latestServerVersion } = caps as Record<string, unknown>
  if (typeof serverVersion !== 'string' || !VERSION_RE.test(serverVersion)) return null
  const release = typeof serverRelease === 'string' && /^[\w.-]{1,128}$/.test(serverRelease) ? serverRelease : null
  let update: ServerInfo['update'] = { state: 'unknown' }
  if (typeof latestServerVersion === 'string' && VERSION_RE.test(latestServerVersion)) {
    update = compareVersions(latestServerVersion, serverVersion) > 0
      ? { state: 'available', latest: latestServerVersion }
      : { state: 'current', latest: latestServerVersion }
  }
  return { version: serverVersion, release, update }
}
