import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick } from 'vue'
import { createMemoryHistory, createRouter } from 'vue-router'
import api from '../api'
import { rememberPeople } from '../people'
import { describeLifetime, lifetimeToMinutes, parseSettings, splitLifetime } from '../settings'
import { useToast } from '../useToast'
import PersonHeader from '../components/PersonHeader.vue'
import ResetSettingsCard from '../components/ResetSettingsCard.vue'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return { ...actual, default: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() } }
})

const get = vi.mocked(api.get)
const post = vi.mocked(api.post)
const put = vi.mocked(api.put)

function json(body: unknown, ok = true): Response {
  return { ok, status: ok ? 200 : 409, json: async () => body } as Response
}

async function settle(): Promise<void> {
  for (let i = 0; i < 3; i++) {
    await nextTick()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

const settings = (over: Record<string, unknown> = {}) => ({
  passwordResetMode: null,
  effectivePasswordResetMode: 'manual',
  resetLinkLifetimeMinutes: 45,
  smtpConfigured: false,
  updatedAt: null,
  ...over,
})

describe('reset settings helpers', () => {
  it('shows whole hours as hours and everything else as minutes', () => {
    expect(splitLifetime(60)).toEqual({ value: 1, unit: 'hours' })
    expect(splitLifetime(1440)).toEqual({ value: 24, unit: 'hours' })
    expect(splitLifetime(90)).toEqual({ value: 90, unit: 'minutes' })
    expect(splitLifetime(5)).toEqual({ value: 5, unit: 'minutes' })
    expect(describeLifetime(60)).toBe('1 hour')
    expect(describeLifetime(120)).toBe('2 hours')
    expect(describeLifetime(45)).toBe('45 minutes')
  })

  it('accepts 5 minutes to 24 hours and nothing else', () => {
    expect(lifetimeToMinutes('5', 'minutes')).toEqual({ ok: true, minutes: 5 })
    expect(lifetimeToMinutes('24', 'hours')).toEqual({ ok: true, minutes: 1440 })
    expect(lifetimeToMinutes(' 2 ', 'hours')).toEqual({ ok: true, minutes: 120 })
    for (const [raw, unit] of [['4', 'minutes'], ['0', 'hours'], ['25', 'hours'], ['1441', 'minutes']] as const) {
      expect(lifetimeToMinutes(raw, unit).ok).toBe(false)
    }
    for (const raw of ['', 'abc', '1.5', '-3', '1e2']) {
      expect(lifetimeToMinutes(raw, 'minutes')).toEqual({ ok: false, error: 'Enter a whole number.' })
    }
  })

  it('refuses a settings answer of the wrong shape', () => {
    expect(parseSettings(settings())).not.toBeNull()
    expect(parseSettings(settings({ effectivePasswordResetMode: 'both' }))).toBeNull()
    expect(parseSettings(settings({ resetLinkLifetimeMinutes: '60' }))).toBeNull()
    expect(parseSettings(null)).toBeNull()
  })
})

describe('Password reset settings card', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>
  const toasts = () => useToast().toasts.value.map((t) => t.message)

  async function mount(): Promise<void> {
    root = document.createElement('div')
    document.body.appendChild(root)
    app = createApp(ResetSettingsCard)
    app.mount(root)
    await settle()
  }

  const radio = (value: string) => root.querySelector<HTMLInputElement>(`input[name="reset-mode"][value="${value}"]`)!

  async function submit(): Promise<void> {
    root.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await settle()
  }

  function typeAmount(value: string): void {
    const input = root.querySelector<HTMLInputElement>('#reset-lifetime')!
    input.value = value
    input.dispatchEvent(new Event('input', { bubbles: true }))
  }

  beforeEach(() => {
    get.mockReset()
    put.mockReset()
    useToast().toasts.value = []
  })

  afterEach(() => {
    app.unmount()
    root.remove()
  })

  it('disables the email option, and says why, when the server cannot send email', async () => {
    get.mockResolvedValue(json(settings()))
    await mount()
    expect(radio('email').disabled).toBe(true)
    expect(radio('auto').checked).toBe(true)
    expect(root.textContent).toContain('SMTP_HOST')
    expect(root.querySelector('#reset-email-note')!.textContent).toContain('needs email sending')
    expect(root.textContent).toContain('Right now: you create links yourself')
    expect(root.querySelector('#reset-email-note')!.textContent).toContain('Always mails the link')
  })

  it('says which way automatic currently resolves', async () => {
    get.mockResolvedValue(json(settings({ smtpConfigured: true, effectivePasswordResetMode: 'email' })))
    await mount()
    const automatic = radio('auto').closest('label')!.textContent!
    expect(automatic).toContain('otherwise you create links yourself')
    expect(automatic).toContain('Right now: by email')
  })

  it('reads the unit in the singular for one', async () => {
    get.mockResolvedValue(json(settings({ resetLinkLifetimeMinutes: 60 })))
    await mount()
    const labels = () => [...root.querySelectorAll('select option')].map((o) => o.textContent)
    expect(labels()).toEqual(['minute', 'hour'])
    typeAmount('2')
    await settle()
    expect(labels()).toEqual(['minutes', 'hours'])
  })

  it('shows a stored lifetime in hours when it is a whole number of hours', async () => {
    get.mockResolvedValue(json(settings({ passwordResetMode: 'manual', resetLinkLifetimeMinutes: 120 })))
    await mount()
    expect(radio('manual').checked).toBe(true)
    expect(root.querySelector<HTMLInputElement>('#reset-lifetime')!.value).toBe('2')
    expect(root.querySelector<HTMLSelectElement>('select')!.value).toBe('hours')
  })

  it('saves the mode and the lifetime in minutes', async () => {
    get.mockResolvedValue(json(settings({ smtpConfigured: true, effectivePasswordResetMode: 'email' })))
    put.mockResolvedValue(json(settings({
      smtpConfigured: true, passwordResetMode: 'email', effectivePasswordResetMode: 'email', resetLinkLifetimeMinutes: 90,
    })))
    await mount()
    expect(radio('email').disabled).toBe(false)
    radio('email').checked = true
    radio('email').dispatchEvent(new Event('change', { bubbles: true }))
    typeAmount('90')
    await submit()
    expect(put).toHaveBeenCalledWith('/admin/settings', { passwordResetMode: 'email', resetLinkLifetimeMinutes: 90 })
    expect(toasts()).toContain('Password reset settings saved')
  })

  it('sends null for automatic', async () => {
    get.mockResolvedValue(json(settings({ passwordResetMode: 'manual' })))
    put.mockResolvedValue(json(settings()))
    await mount()
    radio('auto').checked = true
    radio('auto').dispatchEvent(new Event('change', { bubbles: true }))
    await settle()
    await submit()
    expect(put).toHaveBeenCalledWith('/admin/settings', { passwordResetMode: null, resetLinkLifetimeMinutes: 45 })
  })

  it('does not call the server for a lifetime out of range, and says so', async () => {
    get.mockResolvedValue(json(settings()))
    await mount()
    typeAmount('3')
    await submit()
    expect(put).not.toHaveBeenCalled()
    const error = root.querySelector('#reset-lifetime-error')!
    expect(error.textContent).toContain('shortest lifetime is 5 minutes')
    expect(root.querySelector('#reset-lifetime')!.getAttribute('aria-describedby')).toBe('reset-lifetime-error')
    expect(root.querySelector('#reset-lifetime')!.getAttribute('aria-invalid')).toBe('true')
  })

  it('shows the refusal from the server', async () => {
    get.mockResolvedValue(json(settings()))
    put.mockResolvedValue(json({ error: 'Email password reset needs SMTP_HOST to be configured on the server' }, false))
    await mount()
    await submit()
    expect(root.querySelector('.form-error')!.textContent).toContain('SMTP_HOST')
  })

  it('offers a retry when the settings cannot be read', async () => {
    get.mockResolvedValue(json({}, false))
    await mount()
    expect(root.textContent).toContain('Could not load these settings')
    get.mockResolvedValue(json(settings()))
    root.querySelector<HTMLButtonElement>('.error-state button')!.click()
    await settle()
    expect(root.querySelector('form')).not.toBeNull()
  })
})

describe('Create reset link', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>
  const id = '11111111-1111-4111-8111-111111111111'

  const dialog = () => document.querySelector<HTMLElement>('[role="dialog"], [role="alertdialog"]')
  function button(text: string): HTMLButtonElement {
    const found = [...document.querySelectorAll('button')].find((b) => b.textContent?.includes(text))
    if (!found) throw new Error(`no button "${text}"`)
    return found
  }
  async function click(text: string): Promise<void> {
    button(text).click()
    await settle()
  }

  beforeEach(async () => {
    post.mockReset()
    localStorage.clear()
    rememberPeople([{ id, email: 'mara@example.test', createdAt: '2026-10-01T10:00:00Z' }])
    root = document.createElement('div')
    document.body.appendChild(root)
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/:p(.*)*', component: { template: '<i />' } }],
    })
    app = createApp({ components: { PersonHeader }, template: `<PersonHeader id="${id}" tab="keys" />` })
    app.use(router)
    app.mount(root)
    await settle()
  })

  afterEach(() => {
    app.unmount()
    root.remove()
    document.body.innerHTML = ''
  })

  it('asks first, explains one-time use, and creates nothing until confirmed', async () => {
    await click('Create reset link')
    expect(dialog()!.getAttribute('role')).toBe('alertdialog')
    expect(dialog()!.textContent).toContain('mara@example.test')
    expect(dialog()!.textContent).toContain('works once')
    expect(dialog()!.textContent).toContain('Any earlier link')
    expect(post).not.toHaveBeenCalled()
    await click('Cancel')
    expect(dialog()).toBeNull()
    expect(post).not.toHaveBeenCalled()
  })

  it('shows the link once with a copy button and an expiry, and forgets it on close', async () => {
    const link = 'https://notes.example.test/reset-password#token=abc123secret'
    post.mockResolvedValue(json({ link, expiresAt: '2026-10-20T12:00:00.000Z' }))
    await click('Create reset link')
    await click('Create link')
    expect(post).toHaveBeenCalledWith(`/admin/users/${id}/reset-link`, {})
    expect(dialog()!.textContent).toContain('Expires')
    expect(dialog()!.textContent).toContain('will not be shown again')
    expect(button('Copy link')).toBeTruthy()
    expect(dialog()!.getAttribute('role')).toBe('dialog')
    // The link text is decoded into place; a finished frame shows all of it.
    await new Promise((resolve) => setTimeout(resolve, 1100))
    expect(dialog()!.textContent).toContain('abc123secret')

    await click('Done')
    expect(dialog()).toBeNull()
    expect(document.body.textContent).not.toContain('abc123secret')
    for (let i = 0; i < localStorage.length; i++) {
      expect(localStorage.getItem(localStorage.key(i)!)).not.toContain('abc123secret')
    }
  })

  it('does not close on Escape once the link is showing', async () => {
    post.mockResolvedValue(json({ link: 'https://x.test/#token=zzz', expiresAt: '2026-10-20T12:00:00.000Z' }))
    await click('Create reset link')
    await click('Create link')
    dialog()!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await settle()
    expect(dialog()).not.toBeNull()
  })

  it('says why when the link could not be created, and stays on the question', async () => {
    post.mockResolvedValue(json({ error: 'User not found' }, false))
    await click('Create reset link')
    await click('Create link')
    expect(dialog()!.querySelector('.form-error')!.textContent).toContain('User not found')
    expect(dialog()!.getAttribute('role')).toBe('alertdialog')
  })
})
