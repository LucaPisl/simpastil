import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick } from 'vue'
import { createMemoryHistory, createRouter } from 'vue-router'
import ResetPasswordPage from './ResetPasswordPage.vue'
import InviteAcceptPage from './InviteAcceptPage.vue'
import api from '../api'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    default: { ...actual.default, publicPost: vi.fn() },
  }
})

const publicPost = vi.mocked(api.publicPost)
const LINK_TOKEN = 'raw-link-token-marker-which-must-leave-the-address-bar'
const API_KEY = 'revealed-once-api-key-marker'

function response(body: unknown, ok = false): Response {
  return { ok, json: async () => body } as Response
}

async function settle(): Promise<void> {
  await nextTick()
  await new Promise((resolve) => setTimeout(resolve, 0))
  await nextTick()
}

describe('account recovery pages', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>
  let router: ReturnType<typeof createRouter>

  async function mount(page: typeof ResetPasswordPage | typeof InviteAcceptPage, path: string): Promise<void> {
    root = document.createElement('div')
    document.body.appendChild(root)
    router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/reset-password', component: page },
        { path: '/invite', component: page },
      ],
    })
    await router.push(path)
    await router.isReady()
    app = createApp({ template: '<RouterView />' })
    app.use(router)
    app.mount(root)
    await settle()
  }

  beforeEach(() => publicPost.mockReset())

  afterEach(() => {
    app?.unmount()
    root?.remove()
  })

  it('removes the reset token from navigation before submitting it only in the HTTPS body', async () => {
    publicPost.mockResolvedValue(response({ ok: true }, true))
    await mount(ResetPasswordPage, `/reset-password?token=${encodeURIComponent(LINK_TOKEN)}`)

    expect(router.currentRoute.value.fullPath).toBe('/reset-password')
    expect(root.textContent).not.toContain(LINK_TOKEN)
    // A page for people, not administrators: the side panel is not the console.
    expect(root.querySelector('.auth-eyebrow')?.textContent).toBe('Password reset')
    expect(root.textContent).not.toContain('Server console')
    const input = root.querySelector<HTMLInputElement>('#new-password')!
    input.value = 'correct-horse-battery-staple'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    root.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await settle()

    expect(publicPost).toHaveBeenCalledWith('/auth/reset-password', {
      token: LINK_TOKEN,
      newPassword: 'correct-horse-battery-staple',
    })
    expect(root.textContent).toContain('Your password has been reset')
    expect(root.textContent).toContain('Open the Simpastil app and sign in there')
    expect(root.querySelector('a[href="#/login"]')).toBeNull()
    expect(root.textContent).not.toContain(LINK_TOKEN)
    expect(router.currentRoute.value.fullPath).toBe('/reset-password')
  })

  it('keeps reset failures accessible and never puts the token back in the URL', async () => {
    publicPost.mockResolvedValue(response({ error: { message: 'Reset link has expired' } }))
    await mount(ResetPasswordPage, `/reset-password?token=${encodeURIComponent(LINK_TOKEN)}`)
    root.querySelector<HTMLInputElement>('#new-password')!.value = 'valid-password-123'
    root.querySelector<HTMLInputElement>('#new-password')!.dispatchEvent(new Event('input', { bubbles: true }))
    root.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await settle()

    expect(root.querySelector('[role="alert"]')?.textContent).toContain('Reset link has expired')
    expect(root.querySelector('button')?.hasAttribute('disabled')).toBe(false)
    expect(router.currentRoute.value.fullPath).toBe('/reset-password')
  })

  it('reveals the invitation API key only after acceptance and supports explicit clipboard copy', async () => {
    publicPost.mockResolvedValue({
      ok: true,
      json: async () => ({ serverUrl: 'https://api.example.invalid', apiKey: API_KEY }),
    } as Response)
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText } })
    await mount(InviteAcceptPage, `/invite?token=${encodeURIComponent(LINK_TOKEN)}`)
    // People joining the app, not administrators; no phone-only wording.
    expect(root.querySelector('.auth-eyebrow')?.textContent).toBe('Invitation')
    expect(root.textContent).not.toContain('Server console')
    expect(root.querySelector('.auth-headline')?.textContent).not.toMatch(/phone/i)

    expect(router.currentRoute.value.fullPath).toBe('/invite')
    expect(root.textContent).not.toContain(API_KEY)
    root.querySelector('button')!.dispatchEvent(new Event('click', { bubbles: true }))
    await settle()

    expect(publicPost).toHaveBeenCalledWith('/auth/invite/accept', { token: LINK_TOKEN })
    expect(root.querySelector<HTMLInputElement>('#server-url')?.value).toBe('https://api.example.invalid')
    expect(root.querySelector<HTMLTextAreaElement>('#invite-key')?.value).toBe(API_KEY)
    root.querySelector('button')!.dispatchEvent(new Event('click', { bubbles: true }))
    await settle()
    expect(writeText).toHaveBeenCalledWith(API_KEY)
    expect(root.textContent).toContain('Copied')
    expect(router.currentRoute.value.fullPath).toBe('/invite')
    expect(router.currentRoute.value.fullPath).not.toContain(LINK_TOKEN)
  })

  it('renders invitation failures without exposing the token or revealing an API key', async () => {
    publicPost.mockResolvedValue(response({ error: 'Invitation is no longer valid' }))
    await mount(InviteAcceptPage, `/invite?token=${encodeURIComponent(LINK_TOKEN)}`)
    root.querySelector('button')!.dispatchEvent(new Event('click', { bubbles: true }))
    await settle()

    expect(root.querySelector('[role="alert"]')?.textContent).toContain('Invitation is no longer valid')
    expect(root.textContent).not.toContain(LINK_TOKEN)
    expect(root.textContent).not.toContain(API_KEY)
    expect(root.querySelector('#invite-key')).toBeNull()
    expect(router.currentRoute.value.fullPath).toBe('/invite')
  })
})
