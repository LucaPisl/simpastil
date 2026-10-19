import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, defineComponent, h, nextTick } from 'vue'
import { createMemoryHistory, createRouter, RouterView, type Router } from 'vue-router'
import AppShell from './App.vue'
import DashboardPage from './pages/DashboardPage.vue'
import api from './api'
import { setTheme, theme } from './theme'
import { useToast } from './useToast'

vi.mock('./api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./api')>()
  return { ...actual, default: { get: vi.fn(), post: vi.fn() } }
})

const get = vi.mocked(api.get)
const post = vi.mocked(api.post)

function json(body: unknown, ok = true): Response {
  return { ok, json: async () => body } as Response
}

async function settle(): Promise<void> {
  for (let i = 0; i < 3; i++) {
    await nextTick()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

const Stub = (name: string) => defineComponent({ render: () => h('div', name) })

describe('admin shell', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>
  let router: Router

  async function mountAt(path: string): Promise<void> {
    router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/login', component: Stub('login') },
        {
          path: '/',
          component: AppShell,
          children: [
            { path: 'dashboard', component: DashboardPage },
            { path: 'users', component: Stub('users page') },
            { path: 'users/:id/keys', component: Stub('user keys page') },
            { path: 'keys', component: Stub('keys page') },
            { path: 'invites', component: Stub('invites page') },
            { path: 'settings', component: Stub('settings page') },
          ],
        },
      ],
    })
    await router.push(path)
    await router.isReady()
    root = document.createElement('div')
    document.body.appendChild(root)
    app = createApp({ render: () => h(RouterView) })
    app.use(router)
    app.mount(root)
    await settle()
  }

  beforeEach(() => {
    // The dashboard also asks /capabilities directly; keep the test off the network.
    vi.stubGlobal('fetch', vi.fn(async () => json({}, false)))
    get.mockReset()
    post.mockReset()
    post.mockResolvedValue({ ok: true, status: 204 } as Response)
    get.mockImplementation(async (path: string) => {
      if (path === '/admin/users') {
        return json({ users: [
          { id: 'u1', email: 'ana@example.invalid', createdAt: '2026-10-01T00:00:00Z' },
          { id: 'u2', email: 'bo@example.invalid', createdAt: '2026-10-05T00:00:00Z' },
        ] })
      }
      return json({ keys: [
        { id: 'k1', label: 'Kitchen tablet', revokedAt: null, lastUsedAt: null },
        { id: 'k2', label: 'Lost phone', revokedAt: '2026-01-01T00:00:00Z', lastUsedAt: null },
      ] })
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    app.unmount()
    root.remove()
    setTheme('auto')
  })

  it('marks the owning section of a nested page as current', async () => {
    await mountAt('/users/u1/keys')
    const current = root.querySelectorAll('[aria-current="page"]')
    expect(current).toHaveLength(1)
    expect(current[0].textContent).toContain('People')
    expect(root.textContent).toContain('user keys page')
  })

  it('opens and closes the phone menu with its button, Escape and navigation', async () => {
    await mountAt('/keys')
    const toggle = root.querySelector<HTMLButtonElement>('button[aria-controls="admin-sidebar"]')!
    const sidebar = root.querySelector('#admin-sidebar')!
    expect(toggle.getAttribute('aria-expanded')).toBe('false')

    toggle.click()
    await nextTick()
    expect(toggle.getAttribute('aria-expanded')).toBe('true')
    expect(sidebar.classList.contains('open')).toBe(true)

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await nextTick()
    expect(toggle.getAttribute('aria-expanded')).toBe('false')

    toggle.click()
    await nextTick()
    await router.push('/settings')
    await settle()
    expect(toggle.getAttribute('aria-expanded')).toBe('false')
  })

  it('switches theme from the sidebar and reports the pressed choice', async () => {
    await mountAt('/keys')
    const dark = [...root.querySelectorAll<HTMLButtonElement>('.sidebar .segmented-option')]
      .find((b) => b.textContent?.includes('Dark'))!
    dark.click()
    await nextTick()
    expect(theme.value).toBe('dark')
    expect(dark.getAttribute('aria-pressed')).toBe('true')
    expect(document.documentElement.classList.contains('dark')).toBe(true)
  })

  it('signs out on the server first, then clears both tokens', async () => {
    localStorage.setItem('admin_token', 't')
    localStorage.setItem('admin_refresh_token', 'r')
    await mountAt('/keys')
    const signOut = [...root.querySelectorAll<HTMLButtonElement>('button')]
      .find((b) => b.textContent?.includes('Sign out'))!
    signOut.click()
    await settle()
    expect(post).toHaveBeenCalledWith('/admin/auth/logout', {})
    expect(localStorage.getItem('admin_token')).toBeNull()
    expect(localStorage.getItem('admin_refresh_token')).toBeNull()
    expect(router.currentRoute.value.path).toBe('/login')
  })

  it('still signs out here when the server cannot be reached, and says so', async () => {
    localStorage.setItem('admin_token', 't')
    localStorage.setItem('admin_refresh_token', 'r')
    post.mockRejectedValue(new Error('offline'))
    await mountAt('/keys')
    ;[...root.querySelectorAll<HTMLButtonElement>('button')]
      .find((b) => b.textContent?.includes('Sign out'))!.click()
    await settle()
    expect(localStorage.getItem('admin_token')).toBeNull()
    expect(router.currentRoute.value.path).toBe('/login')
    expect(useToast().toasts.value.map((t) => t.message).join(' ')).toContain('could not confirm')
  })

  it('renders the overview from the same two admin calls, in words', async () => {
    await mountAt('/dashboard')
    expect(get).toHaveBeenCalledWith('/admin/users')
    expect(get).toHaveBeenCalledWith('/admin/keys')
    expect(root.querySelector('.hero-summary')!.textContent).toContain('2 people and 1 active key on this server.')
    expect(root.querySelector('[aria-label="1 of 2 keys active"]')).not.toBeNull()
    expect(root.textContent).toContain('Kitchen tablet')
    expect(root.textContent).not.toContain('Lost phone')
  })

  it('offers a retry when the overview fails, and recovers', async () => {
    get.mockResolvedValueOnce(json({}, false)).mockResolvedValueOnce(json({}, false))
    await mountAt('/dashboard')
    const alert = root.querySelector('[role="alert"]')!
    expect(alert.textContent).toContain('Could not load dashboard data.')

    alert.querySelector('button')!.click()
    await settle()
    expect(root.querySelector('[role="alert"]')).toBeNull()
    expect(root.querySelector('.hero-summary')!.textContent).toContain('2 people')
  })
})
