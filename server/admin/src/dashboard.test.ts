import { describe, expect, it } from 'vitest'
import { initial, relativeDay, serverInfo, serverUpdateBanner, summarize } from './dashboard'
import { activeNavIndex } from './nav'

const users = [
  { id: 'a', email: 'old@example.invalid', createdAt: '2026-01-01T10:00:00Z' },
  { id: 'b', email: 'new@example.invalid', createdAt: '2026-10-10T10:00:00Z' },
  { id: 'c', email: 'mid@example.invalid', createdAt: '2026-06-01T10:00:00Z' },
]
const keys = [
  { id: 'k1', label: 'Never used', revokedAt: null, lastUsedAt: null },
  { id: 'k2', label: 'Recent', revokedAt: null, lastUsedAt: '2026-10-11T08:00:00Z' },
  { id: 'k3', label: 'Revoked', revokedAt: '2026-05-01T00:00:00Z', lastUsedAt: '2026-10-12T08:00:00Z' },
  { id: 'k4', label: 'Older', revokedAt: null, lastUsedAt: '2026-09-01T08:00:00Z' },
]

describe('summarize', () => {
  it('counts people and active versus revoked keys', () => {
    const o = summarize(users, keys)
    expect(o.users).toBe(3)
    expect(o.activeKeys).toBe(3)
    expect(o.revokedKeys).toBe(1)
    expect(o.activeShare).toBeCloseTo(0.75)
    expect(o.summary).toBe('3 people and 3 active keys on this server.')
  })

  it('orders people by join date and keys by last use, leaving revoked keys out', () => {
    const o = summarize(users, keys)
    expect(o.recentUsers.map((u) => u.id)).toEqual(['b', 'c', 'a'])
    expect(o.recentKeys.map((k) => k.id)).toEqual(['k2', 'k4', 'k1'])
  })

  it('respects the limit', () => {
    expect(summarize(users, keys, 1).recentUsers).toHaveLength(1)
  })

  it('uses singular words and an inviting empty summary', () => {
    expect(summarize([users[0]], [keys[1]]).summary).toBe('1 person and 1 active key on this server.')
    const empty = summarize([], [])
    expect(empty.activeShare).toBe(0)
    expect(empty.summary).toMatch(/Invite the first person/)
  })
})

describe('relativeDay', () => {
  const now = new Date(2026, 9, 12, 15, 0)

  it('speaks in calm, approximate words', () => {
    expect(relativeDay(new Date(2026, 9, 12, 1).toISOString(), now)).toBe('today')
    expect(relativeDay(new Date(2026, 9, 11, 23).toISOString(), now)).toBe('yesterday')
    expect(relativeDay(new Date(2026, 9, 8, 12).toISOString(), now)).toBe('4 days ago')
    expect(relativeDay(new Date(2026, 8, 1).toISOString(), now)).toMatch(/2026/)
  })

  it('handles missing or broken dates', () => {
    expect(relativeDay(null, now)).toBe('never')
    expect(relativeDay('not a date', now)).toBe('never')
  })
})

describe('initial', () => {
  it('takes the first letter, upper-cased', () => {
    expect(initial('maria@example.invalid')).toBe('M')
    expect(initial('  ')).toBe('?')
  })
})

describe('activeNavIndex', () => {
  it('maps sections and their nested pages', () => {
    expect(activeNavIndex('/dashboard')).toBe(0)
    expect(activeNavIndex('/users')).toBe(1)
    expect(activeNavIndex('/users/abc/devices')).toBe(1)
    expect(activeNavIndex('/keys')).toBe(2)
    expect(activeNavIndex('/audit')).toBe(4)
    expect(activeNavIndex('/settings')).toBe(5)
  })

  it('does not match on a shared prefix or unknown paths', () => {
    expect(activeNavIndex('/usersx')).toBe(-1)
    expect(activeNavIndex('/login')).toBe(-1)
  })
})

describe('serverUpdateBanner', () => {
  const url = 'https://github.com/LucaPisl/simpastil/releases/tag/v1.1.0'
  it('returns the banner for a newer release', () => {
    expect(serverUpdateBanner({ serverVersion: '1.0.0', latestServerVersion: '1.1.0', latestReleaseUrl: url }))
      .toEqual({ version: '1.1.0', url })
    expect(serverUpdateBanner({ serverVersion: '1.9.0', latestServerVersion: '1.10.0', latestReleaseUrl: url }))
      .toEqual({ version: '1.10.0', url })
  })
  it('returns null for equal, older, missing or foreign data', () => {
    expect(serverUpdateBanner({ serverVersion: '1.1.0', latestServerVersion: '1.1.0', latestReleaseUrl: url })).toBeNull()
    expect(serverUpdateBanner({ serverVersion: '2.0.0', latestServerVersion: '1.1.0', latestReleaseUrl: url })).toBeNull()
    expect(serverUpdateBanner({ serverVersion: '1.0.0' })).toBeNull()
    expect(serverUpdateBanner({ latestServerVersion: '1.1.0', latestReleaseUrl: url })).toBeNull()
    expect(serverUpdateBanner({ serverVersion: '1.0.0', latestServerVersion: '1.1.0', latestReleaseUrl: 'https://evil.example/x' })).toBeNull()
    expect(serverUpdateBanner(null)).toBeNull()
  })
})

describe('serverInfo', () => {
  const caps = { serverVersion: '1.2.0', serverRelease: 'migration-0026', latestServerVersion: '1.3.0' }

  it('reads the running version, the release id and a newer release', () => {
    expect(serverInfo(caps)).toEqual({ version: '1.2.0', release: 'migration-0026', update: { state: 'available', latest: '1.3.0' } })
  })

  it('says current when the latest release is not newer', () => {
    expect(serverInfo({ ...caps, latestServerVersion: '1.2.0' })!.update).toEqual({ state: 'current', latest: '1.2.0' })
  })

  it('claims nothing when the update check has not answered', () => {
    const { latestServerVersion: _omitted, ...without } = caps
    expect(serverInfo(without)!.update).toEqual({ state: 'unknown' })
    expect(serverInfo({ ...caps, latestServerVersion: 'latest' })!.update).toEqual({ state: 'unknown' })
  })

  it('drops an odd release id and refuses a missing or malformed version', () => {
    expect(serverInfo({ ...caps, serverRelease: '<script>' })!.release).toBeNull()
    expect(serverInfo({ serverRelease: 'x' })).toBeNull()
    expect(serverInfo(null)).toBeNull()
    expect(serverInfo({ serverVersion: 'v1' })).toBeNull()
  })
})
