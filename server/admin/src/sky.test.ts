import { describe, expect, it } from 'vitest'
import { greeting, orbAt, skyLabel, skyPhase, skyStops, stars, sunTimes, type SkyPhase } from './sky'

const at = (h: number, m = 0, month = 9, day = 12) => new Date(2026, month, day, h, m)

function luminance(hex: string): number {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}

describe('sunTimes', () => {
  it('matches the mid-month anchors on the 15th', () => {
    expect(sunTimes(new Date(2026, 5, 15))).toEqual({ sunrise: 330, sunset: 1265 })
    expect(sunTimes(new Date(2026, 0, 15))).toEqual({ sunrise: 465, sunset: 1025 })
  })

  it('interpolates between neighbouring months', () => {
    const t = sunTimes(at(12, 0, 9, 12)) // between Sep 15 and Oct 15
    expect(t.sunrise).toBeGreaterThan(425)
    expect(t.sunrise).toBeLessThan(460)
    expect(t.sunset).toBeGreaterThan(1125)
    expect(t.sunset).toBeLessThan(1175)
  })

  it('wraps across the year boundary', () => {
    const t = sunTimes(new Date(2026, 11, 28))
    expect(t.sunrise).toBeGreaterThan(455)
    expect(t.sunrise).toBeLessThan(465)
  })
})

describe('skyPhase', () => {
  it.each<[number, number, SkyPhase]>([
    [3, 0, 'night'],
    [7, 30, 'dawn'],
    [12, 0, 'day'],
    [18, 30, 'dusk'],
    [22, 0, 'night'],
  ])('%i:%i in October is %s', (h, m, phase) => {
    expect(skyPhase(at(h, m))).toBe(phase)
  })
})

describe('skyStops', () => {
  const phases: SkyPhase[] = ['dawn', 'day', 'dusk', 'night']

  it('keeps light skies bright enough for ink text without a scrim', () => {
    for (const p of phases) for (const c of skyStops(p, false)) expect(luminance(c)).toBeGreaterThanOrEqual(0.8)
  })

  it('keeps dark skies dark enough for white text without a scrim', () => {
    for (const p of phases) for (const c of skyStops(p, true)) expect(luminance(c)).toBeLessThanOrEqual(0.03)
  })
})

describe('orbAt', () => {
  it('shows a moon at night and a sun by day', () => {
    expect(orbAt(at(23)).kind).toBe('moon')
    expect(orbAt(at(12)).kind).toBe('sun')
  })

  it('walks the sun left to right and peaks near solar noon', () => {
    const morning = orbAt(at(9))
    const noon = orbAt(at(13, 15))
    const evening = orbAt(at(17))
    expect(morning.x).toBeLessThan(noon.x)
    expect(noon.x).toBeLessThan(evening.x)
    expect(noon.lift).toBeGreaterThan(0.95)
    expect(morning.lift).toBeLessThan(noon.lift)
  })

  it('lets the sun only dip just below the horizon around sunrise', () => {
    const early = orbAt(at(7, 10))
    expect(early.kind).toBe('sun')
    expect(early.lift).toBeLessThan(0)
    expect(early.lift).toBeGreaterThan(-0.1)
  })
})

describe('stars', () => {
  it('is deterministic and stays in the upper sky', () => {
    const a = stars()
    expect(stars()).toEqual(a)
    expect(a).toHaveLength(18)
    for (const s of a) {
      expect(s.x).toBeGreaterThanOrEqual(0)
      expect(s.x).toBeLessThan(1)
      expect(s.y).toBeLessThan(0.7)
      expect(s.delay).toBeLessThanOrEqual(480)
    }
  })
})

describe('words', () => {
  it('greets by the hour', () => {
    expect(greeting(at(4))).toBe('Good night')
    expect(greeting(at(9))).toBe('Good morning')
    expect(greeting(at(14))).toBe('Good afternoon')
    expect(greeting(at(20))).toBe('Good evening')
    expect(greeting(at(23))).toBe('Good night')
  })

  it('names every phase', () => {
    expect(skyLabel('dusk')).toBe('Dusk sky')
  })
})
