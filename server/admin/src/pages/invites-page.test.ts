import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick } from 'vue'
import { createMemoryHistory, createRouter } from 'vue-router'
import InvitesPage from './InvitesPage.vue'
import { useToast } from '../useToast'

function json(body: unknown, ok = true): Response {
  return { ok, status: ok ? 201 : 409, json: async () => body } as Response
}

async function settle(): Promise<void> {
  await nextTick()
  await new Promise((resolve) => setTimeout(resolve, 0))
  await nextTick()
}

/** Lets the out-in swap finish: jsdom never fires transition events. */
async function swap(): Promise<void> {
  await settle()
  await new Promise((resolve) => setTimeout(resolve, 400))
  await settle()
}

describe('InvitesPage', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>
  const fetchMock = vi.fn()
  const toasts = () => useToast().toasts.value.map((t) => t.message)

  beforeEach(async () => {
    localStorage.clear()
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
    useToast().toasts.value = []
    root = document.createElement('div')
    document.body.appendChild(root)
    app = createApp(InvitesPage)
    app.mount(root)
    await settle()
  })

  afterEach(() => {
    app.unmount()
    root.remove()
    vi.unstubAllGlobals()
  })

  function type(selector: string, value: string): void {
    const input = root.querySelector<HTMLInputElement>(selector)!
    input.value = value
    input.dispatchEvent(new Event('input', { bubbles: true }))
  }

  async function sendTo(email: string, label: string): Promise<void> {
    type('#invite-email', email)
    type('#invite-label', label)
    root.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await swap()
  }

  it('a sent invite takes the form’s place, says who it went to, and keeps a log', async () => {
    fetchMock.mockResolvedValue(json({ ok: true }))
    await sendTo('mara@example.test', 'Mara’s phone')

    const post = fetchMock.mock.calls.find((c) => String(c[0]).endsWith('/admin/invites'))!
    const body = JSON.parse(post[1].body)
    expect(body).toEqual({ email: 'mara@example.test', label: 'Mara’s phone' })
    expect(root.querySelector('form')).toBeNull()
    const status = root.querySelector('[role="status"]')!
    expect(status.textContent).toContain('Invitation queued for mara@example.test')
    expect(status.textContent).toContain('“Mara’s phone”')
    expect(root.querySelector('.invite-flight')!.getAttribute('aria-hidden')).toBe('true')
    // The answer is on the page, so no toast repeats it.
    expect(toasts()).toEqual([])
    const again = root.querySelector<HTMLButtonElement>('.invite-sent .btn-secondary')!
    expect(document.activeElement).toBe(again)
    expect([...root.querySelectorAll('.invite-log-email')].map((e) => e.textContent)).toEqual(['mara@example.test'])
  })

  it('“Invite someone else” brings back an empty form with the email focused, newest first in the log', async () => {
    fetchMock.mockResolvedValue(json({ ok: true }))
    await sendTo('mara@example.test', 'Mara’s phone')
    root.querySelector<HTMLButtonElement>('.invite-sent .btn-secondary')!.click()
    await swap()
    const email = root.querySelector<HTMLInputElement>('#invite-email')!
    expect(email.value).toBe('')
    expect(document.activeElement).toBe(email)

    await sendTo('ana@example.test', 'Ana’s tablet')
    expect([...root.querySelectorAll('.invite-log-email')].map((e) => e.textContent)).toEqual([
      'ana@example.test',
      'mara@example.test',
    ])
  })

  it('a refused invite keeps the form and what was typed, and says why', async () => {
    fetchMock.mockResolvedValue(json({ error: 'An invite for this email is already pending' }, false))
    await sendTo('mara@example.test', 'Mara’s phone')
    expect(root.querySelector('[role="status"]')).toBeNull()
    expect(root.querySelector<HTMLInputElement>('#invite-email')!.value).toBe('mara@example.test')
    expect(toasts()).toContain('An invite for this email is already pending')
    expect(root.querySelector('.invite-log')).toBeNull()
  })

  it('explains instead of offering the form while password reset is manual', async () => {
    app.unmount()
    fetchMock.mockReset()
    fetchMock.mockResolvedValue(json({
      passwordResetMode: 'manual',
      effectivePasswordResetMode: 'manual',
      resetLinkLifetimeMinutes: 60,
      smtpConfigured: false,
      updatedAt: null,
    }))
    app = createApp({ components: { InvitesPage }, template: '<InvitesPage />' })
    app.use(createRouter({ history: createMemoryHistory(), routes: [{ path: '/:p(.*)*', component: { template: '<i />' } }] }))
    app.mount(root)
    await settle()
    expect(root.querySelector('form')).toBeNull()
    expect(root.querySelector('#invite-email')).toBeNull()
    expect(root.querySelector('.invite-off')!.textContent).toContain('Email invitations are off')
    expect([...root.querySelectorAll('.invite-off a')].map((a) => a.textContent)).toEqual([
      'Create an API key',
      'Open settings',
    ])
  })
})
