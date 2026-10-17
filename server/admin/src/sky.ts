// Time-of-day sky shared by the admin shell. It mirrors the Flutter app's
// horizon scene (flutter_app/lib/shared/scene): the same 45 N sun table, the
// same phase thresholds and the same palette, so the admin console and the
// phone app share one light. Weather reflects the clock only, never data.

export type SkyPhase = 'dawn' | 'day' | 'dusk' | 'night'

export interface SunTimes {
  sunrise: number // local minutes after midnight
  sunset: number
}

// Mid-month anchors (day 15), daylight saving folded in. Decoration, not an almanac.
const ANCHORS: ReadonlyArray<readonly [number, number]> = [
  [465, 1025], [440, 1065], [390, 1095], [395, 1200], [350, 1235], [330, 1265],
  [350, 1260], [385, 1225], [425, 1175], [460, 1125], [410, 1015], [455, 1010],
]

const DAY_MS = 86_400_000

export function sunTimes(date: Date): SunTimes {
  const day = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  const mid = new Date(date.getFullYear(), date.getMonth(), 15)
  const before = day < mid
  const other = new Date(date.getFullYear(), date.getMonth() + (before ? -1 : 1), 15)
  const span = Math.round(Math.abs(other.getTime() - mid.getTime()) / DAY_MS)
  const t = Math.round(Math.abs(day.getTime() - mid.getTime()) / DAY_MS) / span
  const a = ANCHORS[date.getMonth()]
  const b = ANCHORS[other.getMonth()]
  return {
    sunrise: a[0] + (b[0] - a[0]) * t,
    sunset: a[1] + (b[1] - a[1]) * t,
  }
}

export function minuteOfDay(date: Date): number {
  return date.getHours() * 60 + date.getMinutes() + date.getSeconds() / 60
}

export function skyPhase(date: Date): SkyPhase {
  const m = minuteOfDay(date)
  const t = sunTimes(date)
  if (m < t.sunrise - 45 || m >= t.sunset + 50) return 'night'
  if (m < t.sunrise + 80) return 'dawn'
  if (m < t.sunset - 70) return 'day'
  return 'dusk'
}

// Top, middle and horizon stops. Light skies never go dark (luminance >= .8)
// and dark skies never go bright, so ink or white text needs no scrim.
const LIGHT: Record<SkyPhase, readonly [string, string, string]> = {
  night: ['#E9E6FB', '#ECE9FB', '#F2F0FD'],
  dawn: ['#F0E4FB', '#FBE6EE', '#FFE6CE'],
  day: ['#E4EBFE', '#EEF2FF', '#F8F9FF'],
  dusk: ['#F0E4FB', '#FCE4EB', '#FFE5D0'],
}

const DARK: Record<SkyPhase, readonly [string, string, string]> = {
  night: ['#0A0A16', '#120F2E', '#1E1840'],
  dawn: ['#1A1250', '#2A2152', '#3E2842'],
  day: ['#0F1438', '#1A2050', '#202A5C'],
  dusk: ['#160F34', '#2C1B48', '#3E2842'],
}

export function skyStops(phase: SkyPhase, dark: boolean): readonly [string, string, string] {
  return (dark ? DARK : LIGHT)[phase]
}

export interface Orb {
  kind: 'sun' | 'moon'
  /** Horizontal position, 0..1 of the scene width. */
  x: number
  /** Height above the horizon, 0 (on it) .. 1 (top of the arc); negative is below. */
  lift: number
}

/**
 * The sun walks an arc from sunrise to sunset. Just before sunrise and just
 * after sunset it sits a little under the horizon so the halo reads as a
 * rising or setting sun. At night a moon hangs still in the upper right.
 */
export function orbAt(date: Date): Orb {
  if (skyPhase(date) === 'night') return { kind: 'moon', x: 0.74, lift: 0.78 }
  const m = minuteOfDay(date)
  const s = sunTimes(date)
  const raw = (m - s.sunrise) / (s.sunset - s.sunrise)
  const t = Math.min(1.06, Math.max(-0.06, raw))
  // Outside daylight the sun only dips: its top still peeks over the horizon.
  const lift = t < 0 || t > 1 ? -0.03 : Math.sin(Math.PI * t)
  return { kind: 'sun', x: 0.1 + t * 0.8, lift }
}

export interface Star {
  x: number // 0..1
  y: number // 0..1 of the sky above the horizon
  r: number // px
  delay: number // ms, entry stagger
}

/** Deterministic sparse stars so the sky does not reshuffle between renders. */
export function stars(count = 18, seed = 7): Star[] {
  let s = seed >>> 0
  const next = (): number => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0
    return s / 4294967296
  }
  return Array.from({ length: count }, (_, i) => ({
    x: next(),
    y: next() * 0.7,
    r: next() < 0.18 ? 1.6 : 1,
    delay: Math.min(i, 8) * 60,
  }))
}

export function greeting(date: Date): string {
  const h = date.getHours()
  if (h < 5) return 'Good night'
  if (h < 12) return 'Good morning'
  if (h < 18) return 'Good afternoon'
  if (h < 22) return 'Good evening'
  return 'Good night'
}

/** Words for the sky, so meaning never lives in colour alone. */
export function skyLabel(phase: SkyPhase): string {
  switch (phase) {
    case 'dawn': return 'Dawn sky'
    case 'day': return 'Daytime sky'
    case 'dusk': return 'Dusk sky'
    case 'night': return 'Night sky'
  }
}
