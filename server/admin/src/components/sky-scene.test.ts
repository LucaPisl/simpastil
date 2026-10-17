import { afterEach, describe, expect, it, vi } from 'vitest'
import { createApp, h, nextTick } from 'vue'
import SkyScene from './SkyScene.vue'
import { isDark, resolveDark, setTheme } from '../theme'

let root: HTMLDivElement | null = null
let app: ReturnType<typeof createApp> | null = null

function mount(props: Record<string, unknown>, slot = 'hello'): HTMLDivElement {
  root = document.createElement('div')
  document.body.appendChild(root)
  app = createApp({ render: () => h(SkyScene, props, { default: () => slot }) })
  app.mount(root)
  return root
}

afterEach(() => {
  app?.unmount()
  root?.remove()
  app = null
  root = null
  vi.useRealTimers()
  setTheme('auto')
})

describe('SkyScene', () => {
  it('draws a daytime sun without stars and keeps its slot content', () => {
    const el = mount({ now: new Date(2026, 9, 12, 12, 0) })
    const sky = el.querySelector('.sky')!
    expect(sky.getAttribute('data-phase')).toBe('day')
    expect(el.querySelector('.sky-sun')).not.toBeNull()
    expect(el.querySelectorAll('.sky-star')).toHaveLength(0)
    expect(el.querySelector('.sky-content')!.textContent).toContain('hello')
  })

  it('hangs a moon and stars at night', () => {
    const el = mount({ now: new Date(2026, 9, 12, 23, 0) })
    expect(el.querySelector('.sky')!.getAttribute('data-phase')).toBe('night')
    expect(el.querySelector('.sky-moon')).not.toBeNull()
    expect(el.querySelectorAll('.sky-star').length).toBeGreaterThan(0)
  })

  it('keeps the drawing out of the accessibility tree', () => {
    const el = mount({ now: new Date(2026, 9, 12, 9, 0) })
    expect(el.querySelector('.sky-art')!.getAttribute('aria-hidden')).toBe('true')
  })

  it('follows the resolved theme', async () => {
    const el = mount({ now: new Date(2026, 9, 12, 12, 0) })
    setTheme('dark')
    await nextTick()
    expect(isDark.value).toBe(true)
    expect(el.querySelector('.sky')!.classList.contains('sky-dark')).toBe(true)
    setTheme('light')
    await nextTick()
    expect(el.querySelector('.sky')!.classList.contains('sky-dark')).toBe(false)
    expect(document.documentElement.classList.contains('light')).toBe(true)
  })

  it('schedules no clock when pinned to a moment', () => {
    vi.useFakeTimers()
    mount({ now: new Date(2026, 9, 12, 12, 0) })
    expect(vi.getTimerCount()).toBe(0)
  })

  it('ticks once per minute, aligned to the minute, and stops on unmount', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date(2026, 9, 12, 18, 54, 30))
    const el = mount({})
    expect(vi.getTimerCount()).toBe(1)
    expect(el.querySelector('.sky')!.getAttribute('data-phase')).toBe('dusk')
    vi.advanceTimersByTime(30_000 + 60_000 * 50)
    await nextTick()
    expect(el.querySelector('.sky')!.getAttribute('data-phase')).toBe('night')
    expect(vi.getTimerCount()).toBe(1)
    app!.unmount()
    app = null
    expect(vi.getTimerCount()).toBe(0)
  })
})

describe('resolveDark', () => {
  it('honours explicit choices over the system', () => {
    expect(resolveDark('dark', false)).toBe(true)
    expect(resolveDark('light', true)).toBe(false)
    expect(resolveDark('auto', true)).toBe(true)
    expect(resolveDark('auto', false)).toBe(false)
  })
})
