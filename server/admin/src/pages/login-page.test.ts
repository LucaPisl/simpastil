import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick } from 'vue'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'
import LoginPage from './LoginPage.vue'

function json(body: unknown, ok = true): Response {
  return { ok, status: ok ? 200 : 401, json: async () => body } as Response
}

async function settle(): Promise<void> {
  await nextTick()
  await new Promise((resolve) => setTimeout(resolve, 0))
  await nextTick()
}

describe('LoginPage', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>
  let router: Router
  const fetchMock = vi.fn()

  beforeEach(async () => {
    localStorage.clear()
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
    root = document.createElement('div')
    document.body.appendChild(root)
    router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/login', component: LoginPage },
        { path: '/dashboard', component: { template: '<div>dash</div>' } },
      ],
    })
    await router.push('/login')
    await router.isReady()
    app = createApp(LoginPage)
    app.use(router)
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

  function submit(): void {
    root.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
  }

  it('labels the password field and signs straight in without 2FA', async () => {
    expect(root.querySelector('label[for="admin-login-password"]')).not.toBeNull()
    fetchMock.mockResolvedValueOnce(json({ accessToken: 'a1', refreshToken: 'r1' }))
    type('#admin-login-password', 'secret-password')
    submit()
    await settle()

    expect(fetchMock).toHaveBeenCalledWith('/api/v1/admin/auth/login', expect.objectContaining({
      method: 'POST',
      body: JSON.stringify({ password: 'secret-password' }),
    }))
    expect(localStorage.getItem('admin_token')).toBe('a1')
    expect(localStorage.getItem('admin_refresh_token')).toBe('r1')
    expect(router.currentRoute.value.path).toBe('/dashboard')
  })

  it('asks for a code, sends it with the challenge token and never stores the challenge', async () => {
    fetchMock.mockResolvedValueOnce(json({ requires2fa: true, challengeToken: 'challenge-xyz' }))
    type('#admin-login-password', 'secret-password')
    submit()
    await settle()

    expect(root.textContent).toContain('One more step')
    expect(root.querySelector('#admin-login-totp')).not.toBeNull()
    expect(localStorage.getItem('admin_token')).toBeNull()

    fetchMock.mockResolvedValueOnce(json({ accessToken: 'a2', refreshToken: 'r2' }))
    type('#admin-login-totp', '123456')
    submit()
    await settle()

    expect(fetchMock).toHaveBeenLastCalledWith('/api/v1/admin/auth/2fa/challenge', expect.objectContaining({
      body: JSON.stringify({ challengeToken: 'challenge-xyz', code: '123456' }),
    }))
    expect(localStorage.getItem('admin_token')).toBe('a2')
    expect(router.currentRoute.value.path).toBe('/dashboard')
  })

  it('goes back to the password step from the code step', async () => {
    fetchMock.mockResolvedValueOnce(json({ requires2fa: true, challengeToken: 'c' }))
    type('#admin-login-password', 'secret-password')
    submit()
    await settle()

    const back = [...root.querySelectorAll('button')].find((b) => b.textContent?.includes('different password'))!
    back.dispatchEvent(new Event('click', { bubbles: true }))
    await settle()
    expect(root.querySelector('#admin-login-totp')).toBeNull()
    expect(root.querySelector('#admin-login-password')).not.toBeNull()
  })

  it('reports a failed sign-in and re-enables the button', async () => {
    fetchMock.mockResolvedValueOnce(json({ error: 'Invalid credentials' }, false))
    type('#admin-login-password', 'wrong-password')
    submit()
    await settle()

    expect(document.body.textContent).toContain('Invalid credentials')
    expect(root.querySelector('button[type="submit"]')!.hasAttribute('disabled')).toBe(false)
    expect(router.currentRoute.value.path).toBe('/login')
  })

  it('lets a backup code stand in for the authenticator code', async () => {
    fetchMock.mockResolvedValueOnce(json({ requires2fa: true, challengeToken: 'c' }))
    type('#admin-login-password', 'secret-password')
    submit()
    await settle()

    const toggle = [...root.querySelectorAll('button')].find((b) => b.textContent?.includes('backup code'))!
    toggle.dispatchEvent(new Event('click', { bubbles: true }))
    await settle()
    const input = root.querySelector<HTMLInputElement>('#admin-login-totp')!
    expect(root.querySelector('label[for="admin-login-totp"]')!.textContent).toBe('Backup code')
    expect(input.hasAttribute('pattern')).toBe(false)

    fetchMock.mockResolvedValueOnce(json({ accessToken: 'a3', refreshToken: 'r3' }))
    type('#admin-login-totp', 'abcd1234')
    submit()
    await settle()
    expect(fetchMock).toHaveBeenLastCalledWith('/api/v1/admin/auth/2fa/challenge', expect.objectContaining({
      body: JSON.stringify({ challengeToken: 'c', code: 'abcd1234' }),
    }))
    expect(localStorage.getItem('admin_token')).toBe('a3')
  })
})
