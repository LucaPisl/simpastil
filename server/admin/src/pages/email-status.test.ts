import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick } from 'vue'
import api from '../api'
import { parseEmailStatus, saveSettings } from '../settings'
import EmailStatusCard from '../components/EmailStatusCard.vue'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return { ...actual, default: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() } }
})

const get = vi.mocked(api.get)
const put = vi.mocked(api.put)

function json(body: unknown, ok = true): Response {
  return { ok, status: ok ? 200 : 500, json: async () => body } as Response
}

async function settle(): Promise<void> {
  for (let i = 0; i < 3; i++) {
    await nextTick()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

const status = (over: Record<string, unknown> = {}) => ({
  configured: true,
  effectiveMode: 'email',
  recentPermanentFailures: 0,
  lastPermanentFailureAt: null,
  ...over,
})

describe('parseEmailStatus', () => {
  it('accepts the server answer and refuses odd shapes', () => {
    expect(parseEmailStatus(status())).toEqual(status())
    expect(parseEmailStatus(status({ effectiveMode: 'both' }))).toBeNull()
    expect(parseEmailStatus(status({ recentPermanentFailures: -1 }))).toBeNull()
    expect(parseEmailStatus(status({ lastPermanentFailureAt: 'yesterday' }))).toBeNull()
    expect(parseEmailStatus(null)).toBeNull()
  })
})

describe('Email status card', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>

  async function mount(): Promise<void> {
    root = document.createElement('div')
    document.body.appendChild(root)
    app = createApp(EmailStatusCard)
    app.mount(root)
    await settle()
  }

  beforeEach(() => get.mockReset())
  afterEach(() => {
    app.unmount()
    root.remove()
  })

  it('shows a healthy server without a hint', async () => {
    get.mockResolvedValue(json(status()))
    await mount()
    expect(root.textContent).toContain('Configured')
    expect(root.textContent).toContain('By email')
    expect(root.textContent).toContain('No failed deliveries')
    expect(root.querySelector('.hint')).toBeNull()
  })

  it('says what is missing when the server cannot send email', async () => {
    get.mockResolvedValue(json(status({ configured: false, effectiveMode: 'manual' })))
    await mount()
    expect(root.textContent).toContain('Not configured')
    expect(root.textContent).toContain('Links handed over by you')
    expect(root.querySelector('.hint')!.textContent).toContain('SMTP_HOST')
    expect(root.querySelector('.hint')!.textContent).toContain('DEPLOYMENT.md')
  })

  it('counts recent permanent failures, gives the last time and points to the SMTP settings', async () => {
    get.mockResolvedValue(json(status({ recentPermanentFailures: 3, lastPermanentFailureAt: '2026-10-19T08:30:00.000Z' })))
    await mount()
    expect(root.querySelector('.email-failed')!.textContent).toContain('3 emails could not be delivered')
    expect(root.querySelector('.email-failed small')!.textContent).toContain('Last failure')
    expect(root.querySelector('.hint')!.textContent).toContain('SMTP settings in DEPLOYMENT.md')
  })

  it('uses the singular for one failure', async () => {
    get.mockResolvedValue(json(status({ recentPermanentFailures: 1, lastPermanentFailureAt: '2026-10-19T08:30:00.000Z' })))
    await mount()
    expect(root.querySelector('.email-failed')!.textContent).toContain('1 email could not be delivered')
  })

  it('refreshes the shown reset mode after the reset settings are saved', async () => {
    get.mockResolvedValue(json(status()))
    await mount()
    expect(root.textContent).toContain('By email')

    get.mockResolvedValue(json(status({ effectiveMode: 'manual' })))
    put.mockResolvedValue(json({
      passwordResetMode: 'manual', effectivePasswordResetMode: 'manual', resetLinkLifetimeMinutes: 60, smtpConfigured: true,
    }))
    expect((await saveSettings({ passwordResetMode: 'manual' })).ok).toBe(true)
    await settle()
    expect(root.textContent).toContain('Links handed over by you')
    expect(root.textContent).not.toContain('By email')
  })

  it('does not refresh when a save fails', async () => {
    get.mockResolvedValue(json(status()))
    await mount()
    get.mockClear()
    put.mockResolvedValue(json({ error: 'nope' }, false))
    expect((await saveSettings({ passwordResetMode: 'manual' })).ok).toBe(false)
    await settle()
    expect(get).not.toHaveBeenCalled()
  })

  it('offers a retry when the status cannot be read, and checks again on request', async () => {
    get.mockResolvedValue(json({}, false))
    await mount()
    expect(root.textContent).toContain('Could not load the email status')
    get.mockResolvedValue(json(status()))
    root.querySelector<HTMLButtonElement>('.error-state button')!.click()
    await settle()
    expect(root.textContent).toContain('No failed deliveries')
    get.mockResolvedValue(json(status({ recentPermanentFailures: 2, lastPermanentFailureAt: '2026-10-19T08:30:00.000Z' })))
    ;[...root.querySelectorAll('button')].find((b) => b.textContent?.includes('Check again'))!.click()
    await settle()
    expect(root.textContent).toContain('2 emails')
  })
})
