import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick } from 'vue'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'
import api from '../api'
import { backupCodesFile, groupSecret } from '../twofactor'
import SettingsPage from './SettingsPage.vue'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return { ...actual, default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }
})

const get = vi.mocked(api.get)
const post = vi.mocked(api.post)

function json(body: unknown, ok = true): Response {
  return { ok, status: ok ? 200 : 400, json: async () => body } as Response
}

async function settle(): Promise<void> {
  for (let i = 0; i < 3; i++) {
    await nextTick()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

const CODES = ['1a2b3c4d', '5e6f7a8b', '9c0d1e2f', '3a4b5c6d']

describe('two-factor helpers', () => {
  it('groups a secret in fours', () => {
    expect(groupSecret('ABCDEFGHIJ')).toBe('ABCD EFGH IJ')
  })

  it('writes the download with only the codes and the host', () => {
    const text = backupCodesFile(CODES, 'admin.example', new Date('2026-10-20T10:00:00Z'))
    expect(text).toContain('admin.example')
    expect(text).toContain('2026-10-20')
    for (const code of CODES) expect(text).toContain(code)
  })
})

describe('two-factor settings card', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>
  let router: Router

  async function mount(): Promise<void> {
    root = document.createElement('div')
    document.body.appendChild(root)
    router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/settings', component: SettingsPage },
        { path: '/login', component: { template: '<div>login</div>' } },
      ],
    })
    await router.push('/settings')
    await router.isReady()
    app = createApp({ template: '<RouterView />' })
    app.use(router)
    app.mount(root)
    await settle()
  }

  function typeInto(selector: string, value: string): void {
    const input = document.querySelector<HTMLInputElement>(selector)!
    input.value = value
    input.dispatchEvent(new Event('input', { bubbles: true }))
  }

  function button(text: string): HTMLButtonElement {
    const found = [...document.querySelectorAll('button')].find((b) => b.textContent?.includes(text))
    if (!found) throw new Error(`no button "${text}"`)
    return found
  }

  async function click(text: string): Promise<void> {
    button(text).dispatchEvent(new Event('click', { bubbles: true }))
    await settle()
  }

  async function submitDialog(): Promise<void> {
    document.querySelector('[role="dialog"] form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await settle()
  }

  beforeEach(() => {
    get.mockReset()
    post.mockReset()
    localStorage.clear()
    localStorage.setItem('admin_token', 't')
    localStorage.setItem('admin_refresh_token', 'r')
  })

  afterEach(() => {
    app.unmount()
    root.remove()
    document.body.innerHTML = ''
  })

  it('explains that an environment-managed admin has no two-factor', async () => {
    get.mockResolvedValue(json({ available: false, enabled: false, backupCodesRemaining: 0 }))
    await mount()
    expect(root.textContent).toContain('not available')
    expect(root.textContent).not.toContain('Set up')
  })

  it('sets up with a locally drawn QR code, then shows backup codes once', async () => {
    get.mockResolvedValue(json({ available: true, enabled: false, backupCodesRemaining: 0 }))
    post.mockResolvedValueOnce(json({ secret: 'JBSWY3DPEHPK3PXP', otpauthUri: 'otpauth://totp/Simpastil:a@b.c?secret=JBSWY3DPEHPK3PXP&issuer=Simpastil' }))
    await mount()

    await click('Set up')
    const dialog = document.querySelector('[role="dialog"]')!
    expect(dialog.getAttribute('aria-modal')).toBe('true')
    expect(document.getElementById(dialog.getAttribute('aria-labelledby')!)!.textContent).toContain('Set up')
    expect(dialog.querySelector('svg.qr-code path')).not.toBeNull()
    expect(dialog.textContent).toContain('JBSW Y3DP EHPK 3PXP')
    // The QR code must never be a remote image.
    expect(dialog.querySelector('img')).toBeNull()

    post.mockResolvedValueOnce(json({ backupCodes: CODES }))
    typeInto('#twofactor-code', '123456')
    await submitDialog()
    expect(post).toHaveBeenLastCalledWith('/admin/auth/2fa/enable', { code: '123456' })
    for (const code of CODES) expect(document.body.textContent).toContain(code)

    // The codes cannot be dismissed by accident, and Continue waits for the checkbox.
    document.querySelector('[role="dialog"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await settle()
    expect(document.body.textContent).toContain(CODES[0])
    expect(button('Continue to sign in').disabled).toBe(true)

    const box = document.querySelector<HTMLInputElement>('.check-row input')!
    box.checked = true
    box.dispatchEvent(new Event('change', { bubbles: true }))
    await settle()
    await click('Continue to sign in')

    expect(localStorage.getItem('admin_token')).toBeNull()
    expect(localStorage.getItem('admin_refresh_token')).toBeNull()
    expect(router.currentRoute.value.path).toBe('/login')
    expect(document.body.textContent).not.toContain(CODES[0])
    // Backup codes never reach browser storage.
    expect(JSON.stringify({ ...localStorage })).not.toContain(CODES[0])
  })

  it('keeps the dialog open and says why when the code is wrong', async () => {
    get.mockResolvedValue(json({ available: true, enabled: true, backupCodesRemaining: 8 }))
    await mount()
    expect(root.textContent).toContain('8 unused backup codes')

    await click('New backup codes')
    post.mockResolvedValueOnce(json({ error: 'Invalid TOTP code' }, false))
    typeInto('#twofactor-code', '000000')
    await submitDialog()
    expect(document.querySelector('[role="alert"]')!.textContent).toContain('Invalid TOTP code')
    expect(document.querySelector('[role="dialog"]')).not.toBeNull()
  })

  it('turns two-factor off only with a code', async () => {
    get.mockResolvedValue(json({ available: true, enabled: true, backupCodesRemaining: 1 }))
    await mount()
    expect(root.textContent).toContain('low on backup codes')

    await click('Turn off')
    expect(document.querySelector('[role="dialog"]')).not.toBeNull()
    expect((document.querySelector('[role="dialog"] button[type="submit"]') as HTMLButtonElement).disabled).toBe(true)

    post.mockResolvedValueOnce(json({ ok: true }))
    typeInto('#twofactor-code', '654321')
    await submitDialog()
    expect(post).toHaveBeenLastCalledWith('/admin/auth/2fa/disable', { code: '654321' })

    await click('Continue to sign in')
    expect(router.currentRoute.value.path).toBe('/login')
  })

  it('closes on Escape and returns focus to the button that opened it', async () => {
    get.mockResolvedValue(json({ available: true, enabled: true, backupCodesRemaining: 8 }))
    await mount()
    const opener = button('New backup codes')
    opener.focus()
    await click('New backup codes')
    expect(document.activeElement).toBe(document.querySelector('#twofactor-code'))

    document.querySelector('[role="dialog"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await settle()
    expect(document.querySelector('[role="dialog"]')).toBeNull()
    expect(document.activeElement).toBe(opener)
  })
})
