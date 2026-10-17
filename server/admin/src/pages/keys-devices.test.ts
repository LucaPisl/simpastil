import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, defineComponent, h, nextTick, type Component } from 'vue'
import { createMemoryHistory, createRouter, RouterView } from 'vue-router'
import api from '../api'
import { addedIds, decodeFrame } from '../keys'
import { useToast } from '../useToast'
import KeysPage from './KeysPage.vue'
import UserDevicesPage from './UserDevicesPage.vue'
import UserKeysPage from './UserKeysPage.vue'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return { ...actual, default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }
})

const get = vi.mocked(api.get)
const post = vi.mocked(api.post)
const del = vi.mocked(api.delete)
const toastText = () => useToast().toasts.value.map((t) => t.message).join(' | ')
const RAW = 'spk_live-4fQ9zK2mXw7Rb8Tn'

function json(body: unknown, ok = true): Response {
  return { ok, json: async () => body } as Response
}

async function settle(): Promise<void> {
  for (let i = 0; i < 3; i++) {
    await nextTick()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

function reducedMotion(on: boolean): void {
  vi.stubGlobal('matchMedia', (query: string) => ({ matches: on && query.includes('reduce') }))
}

const kitchenKey = { id: 'k1', label: 'Kitchen tablet', encryptedKey: 'enc', revokedAt: null, lastUsedAt: null, createdAt: '2026-10-01T00:00:00Z' }
// The page marks a key revoked in place; each test gets its own copy.
let kitchen = { ...kitchenKey }
const legacy = { id: 'k2', label: 'Old phone', encryptedKey: null, revokedAt: null, lastUsedAt: null, createdAt: '2026-09-01T00:00:00Z' }

describe('key helpers', () => {
  it('settles a key left to right and keeps its separators', () => {
    const value = 'ab-cd_ef'
    expect(decodeFrame(value, 1)).toBe(value)
    const half = decodeFrame(value, 0.5, () => 0)
    expect(half).toBe('ab-cA_AA')
    expect(decodeFrame(value, 0, () => 0)).toBe('AA-AA_AA')
  })

  it('names the rows a reload added', () => {
    expect(addedIds([{ id: 'a' }], [{ id: 'b' }, { id: 'a' }, { id: 'c' }])).toEqual(['b', 'c'])
  })
})

describe('keys and devices pages', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>

  async function mount(page: Component, path: string, pattern: string): Promise<void> {
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: pattern, component: page },
        { path: '/:rest(.*)*', component: defineComponent({ render: () => h('div', 'elsewhere') }) },
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

  function button(label: string, within: ParentNode = root): HTMLButtonElement {
    const found = [...within.querySelectorAll<HTMLButtonElement>('button')].find(
      (b) => b.textContent?.trim() === label,
    )
    if (!found) throw new Error(`no button "${label}"`)
    return found
  }

  beforeEach(() => {
    kitchen = { ...kitchenKey }
    get.mockReset()
    post.mockReset()
    del.mockReset()
    reducedMotion(false)
  })

  afterEach(() => {
    app?.unmount()
    root?.remove()
    vi.unstubAllGlobals()
    document.body.innerHTML = ''
  })

  it('asks inside the row before revoking, and Keep or Escape take it back', async () => {
    get.mockResolvedValue(json({ keys: [kitchen, legacy] }))
    await mount(KeysPage, '/keys', '/keys')
    const row = root.querySelector('[data-key="k1"]')!

    button('Revoke', row).click()
    await settle()
    const strip = row.querySelector('.confirm-strip')!
    expect(strip.getAttribute('aria-label')).toBe('Revoke “Kitchen tablet”?')
    expect(document.activeElement?.textContent?.trim()).toBe('Keep')
    expect(del).not.toHaveBeenCalled()
    // One question at a time.
    button('Revoke', root.querySelector('[data-key="k2"]')!).click()
    await settle()
    expect(root.querySelectorAll('.confirm-strip')).toHaveLength(1)
    expect(root.querySelector('[data-key="k2"] .confirm-strip')).not.toBeNull()

    button('Keep').click()
    await settle()
    expect(root.querySelector('.confirm-strip')).toBeNull()
    expect(document.activeElement).toBe(button('Revoke', root.querySelector('[data-key="k2"]')!))

    button('Revoke', row).click()
    await settle()
    row.querySelector('.confirm-strip')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await settle()
    expect(root.querySelector('.confirm-strip')).toBeNull()
    expect(del).not.toHaveBeenCalled()
  })

  it('unplugs a revoked key where it stands, without a reload flash', async () => {
    get.mockResolvedValueOnce(json({ keys: [kitchen] }))
    await mount(KeysPage, '/keys', '/keys')
    let release!: (r: Response) => void
    get.mockReturnValueOnce(new Promise<Response>((r) => (release = r)))
    del.mockResolvedValue(json({}))

    const row = root.querySelector('[data-key="k1"]')!
    button('Revoke', row).click()
    await settle()
    button('Revoke key', row).click()
    await settle()

    expect(del).toHaveBeenCalledWith('/admin/keys/k1')
    expect(row.classList.contains('is-revoked')).toBe(true)
    expect(row.classList.contains('is-unplugged')).toBe(true)
    expect(row.querySelector('.status-revoked')).not.toBeNull()
    expect(row.textContent).toContain('Revoked')
    // The list stays while the server is asked again.
    expect(root.querySelector('.skeleton')).toBeNull()
    expect(root.querySelector('[data-key="k1"]')).toBe(row)

    release(json({ keys: [{ ...kitchen, revokedAt: '2026-10-13T06:00:00Z' }] }))
    await settle()
    expect(root.querySelector('[data-key="k1"]')).toBe(row)
    expect(row.querySelector('.label-text')!.textContent).toBe('Kitchen tablet')
  })

  it('keeps the question open when the server refuses', async () => {
    get.mockResolvedValue(json({ keys: [kitchen] }))
    del.mockResolvedValue(json({ error: 'Nope' }, false))
    await mount(KeysPage, '/keys', '/keys')
    const row = root.querySelector('[data-key="k1"]')!
    button('Revoke', row).click()
    await settle()
    button('Revoke key', row).click()
    await settle()
    expect(row.classList.contains('is-revoked')).toBe(false)
    expect(row.querySelector('.confirm-strip')).not.toBeNull()
    expect(toastText()).toContain('Nope')
  })

  it('decodes a revealed key into place, and copies it with a Copied state', async () => {
    get.mockResolvedValueOnce(json({ keys: [kitchen] })).mockResolvedValueOnce(json({ rawKey: RAW }))
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText } })
    await mount(KeysPage, '/keys', '/keys')

    button('Reveal').click()
    await settle()
    const code = root.querySelector('code')!
    expect(code.getAttribute('aria-busy')).toBe('true')
    expect(code.textContent).toHaveLength(RAW.length)
    expect(code.textContent).not.toBe(RAW)

    await vi.waitFor(() => expect(code.textContent).toBe(RAW), { timeout: 2000, interval: 50 })
    expect(code.getAttribute('aria-busy')).toBe('false')

    const copy = root.querySelector<HTMLButtonElement>('.copy-button')!
    copy.click()
    await settle()
    expect(writeText).toHaveBeenCalledWith(RAW)
    expect(copy.classList.contains('is-copied')).toBe(true)
    expect(copy.querySelector('[aria-live]')!.textContent).toBe('Copied')
  })

  it('shows a revealed key at once when motion is reduced', async () => {
    reducedMotion(true)
    get.mockResolvedValueOnce(json({ keys: [kitchen] })).mockResolvedValueOnce(json({ rawKey: RAW }))
    await mount(KeysPage, '/keys', '/keys')
    button('Reveal').click()
    await settle()
    expect(root.querySelector('code')!.textContent).toBe(RAW)
  })

  it('says so when the clipboard refuses', async () => {
    reducedMotion(true)
    get.mockResolvedValueOnce(json({ keys: [kitchen] })).mockResolvedValueOnce(json({ rawKey: RAW }))
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText: vi.fn().mockRejectedValue(new Error('denied')) },
    })
    await mount(KeysPage, '/keys', '/keys')
    button('Reveal').click()
    await settle()
    root.querySelector<HTMLButtonElement>('.copy-button')!.click()
    await settle()
    expect(root.querySelector('.copy-button')!.classList.contains('is-copied')).toBe(false)
    expect(toastText()).toContain('Could not copy')
  })

  it('a new key is a dialog that Escape closes, and its row lights up after', async () => {
    reducedMotion(true)
    get.mockResolvedValueOnce(json({ keys: [kitchen] }))
    await mount(KeysPage, '/keys', '/keys')
    button('New key').click()
    await settle()
    const input = root.querySelector<HTMLInputElement>('#new-key-label')!
    expect(document.activeElement).toBe(input)
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await settle()
    expect(root.querySelector('#new-key-label')).toBeNull()

    button('New key').click()
    await settle()
    const field = root.querySelector<HTMLInputElement>('#new-key-label')!
    field.value = 'Hall phone'
    field.dispatchEvent(new Event('input'))
    post.mockResolvedValue(json({ rawKey: RAW }))
    get.mockResolvedValueOnce(json({ keys: [kitchen, { ...kitchen, id: 'k9', label: 'Hall phone' }] }))
    root.querySelector('form')!.dispatchEvent(new Event('submit'))
    await settle()

    const dialog = root.querySelector('[role="dialog"]')!
    expect(dialog.getAttribute('aria-modal')).toBe('true')
    expect(dialog.querySelector('code')!.textContent).toBe(RAW)
    // Under the dialog, the new row waits to be seen.
    expect(root.querySelector('[data-key="k9"]')!.classList.contains('is-fresh')).toBe(false)

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await settle()
    expect(root.querySelector('[role="dialog"]')).toBeNull()
    expect(root.querySelector('[data-key="k9"]')!.classList.contains('is-fresh')).toBe(true)
    expect(root.querySelector('[data-key="k1"]')!.classList.contains('is-fresh')).toBe(false)
  })

  it("a person's keys use the same row, and the new-key form unfolds in place", async () => {
    get.mockImplementation(async (path: string) =>
      path === '/admin/users'
        ? json({ users: [{ id: 'u1', email: 'mara@example.invalid', createdAt: '2026-10-01T00:00:00Z' }] })
        : json({ keys: [kitchen] }),
    )
    await mount(UserKeysPage, '/users/u1/keys', '/users/:id/keys')
    expect(root.querySelector('[data-key="k1"] .confirm-strip')).toBeNull()
    button('Revoke', root.querySelector('[data-key="k1"]')!).click()
    await settle()
    expect(root.querySelector('[data-key="k1"] .confirm-strip')).not.toBeNull()

    button('New key').click()
    await settle()
    expect(root.querySelector('.fold form')).not.toBeNull()
    expect(document.activeElement).toBe(root.querySelector('#user-new-key-label'))
  })

  it('asks before signing a device out, then folds its row away', async () => {
    let phones = [
      { family_id: 'f1', device_name: 'Pixel 8', last_used_at: '2026-10-12T08:00:00Z' },
      { family_id: 'f2', device_name: null, last_used_at: '2026-10-11T08:00:00Z' },
    ]
    get.mockImplementation(async (path: string) =>
      path === '/admin/users' ? json({ users: [] }) : json({ devices: phones }),
    )
    del.mockImplementation(async (path: string) => {
      phones = phones.filter((p) => !path.endsWith(p.family_id))
      return json({})
    })
    await mount(UserDevicesPage, '/users/u1/devices', '/users/:id/devices')

    const signOuts = () => [...root.querySelectorAll<HTMLButtonElement>('[data-signout]')]
    signOuts()[1]!.click()
    await settle()
    expect(root.querySelector('.confirm-strip')!.getAttribute('aria-label')).toBe('Sign out this device?')
    expect(signOuts()[1]!.getAttribute('aria-expanded')).toBe('true')
    expect(del).not.toHaveBeenCalled()

    signOuts()[0]!.click()
    await settle()
    expect(root.querySelector('.confirm-strip')!.getAttribute('aria-label')).toBe('Sign out Pixel 8?')
    const strip = root.querySelector('.confirm-strip')!
    button('Sign out', strip).click()
    await settle()
    expect(del).toHaveBeenCalledWith('/admin/users/u1/devices/f1')
    expect(root.querySelector('.skeleton')).toBeNull()
    expect(signOuts().map((b) => b.dataset['signout'])).toEqual(['f2'])
  })
})
