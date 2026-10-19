import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick } from 'vue'
import { createMemoryHistory, createRouter } from 'vue-router'
import api from '../api'
import UsersPage from './UsersPage.vue'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return { ...actual, default: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() } }
})

const get = vi.mocked(api.get)

function json(body: unknown): Response {
  return { ok: true, status: 200, json: async () => body } as Response
}

async function settle(): Promise<void> {
  for (let i = 0; i < 3; i++) {
    await nextTick()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

const settings = (mode: 'email' | 'manual') => ({
  passwordResetMode: null,
  effectivePasswordResetMode: mode,
  resetLinkLifetimeMinutes: 60,
  smtpConfigured: mode === 'email',
  updatedAt: null,
})

describe('People page invite button', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>

  async function mount(mode: 'email' | 'manual'): Promise<void> {
    get.mockImplementation(async (path: string) => (path === '/admin/settings' ? json(settings(mode)) : json({ users: [] })))
    root = document.createElement('div')
    document.body.appendChild(root)
    app = createApp(UsersPage)
    app.use(createRouter({ history: createMemoryHistory(), routes: [{ path: '/:p(.*)*', component: { template: '<i />' } }] }))
    app.mount(root)
    await settle()
  }

  beforeEach(() => get.mockReset())
  afterEach(() => {
    app.unmount()
    root.remove()
  })

  it('links to the invites while email works', async () => {
    await mount('email')
    expect(root.querySelector('.page-header a[href="/invites"]')).not.toBeNull()
    expect(root.querySelector('.page-header button[disabled]')).toBeNull()
  })

  it('is disabled and explained while password reset is manual', async () => {
    await mount('manual')
    const button = root.querySelector<HTMLButtonElement>('.page-header button[disabled]')!
    expect(button.getAttribute('aria-describedby')).toBe('invite-off-note')
    expect(root.querySelector('#invite-off-note')!.textContent).toContain('Email invitations are off')
    expect(root.querySelector('.page-header a[href="/invites"]')).toBeNull()
    expect(root.querySelector('a[href="/keys"]')).not.toBeNull()
  })
})
