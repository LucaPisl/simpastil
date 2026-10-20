import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick } from 'vue'
import api from '../api'
import { actionLabel, auditQuery, entryDetails, PAGE_SIZE, type AuditEntry } from '../audit'
import AuditPage from './AuditPage.vue'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return { ...actual, default: { get: vi.fn() } }
})

const get = vi.mocked(api.get)

function json(body: unknown, ok = true): Response {
  return { ok, json: async () => body } as Response
}

async function settle(): Promise<void> {
  for (let i = 0; i < 3; i++) {
    await nextTick()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

function entry(n: number, over: Partial<AuditEntry> = {}): AuditEntry {
  return {
    id: `id-${n}`, actor: 'admin', action: 'key.create', targetType: 'api_key', targetId: `k${n}`,
    metadata: { label: `Phone ${n}` }, ipAddress: '203.0.113.7', createdAt: '2026-10-01T10:00:00.000Z', ...over,
  }
}

describe('audit helpers', () => {
  it('names actions in words, with the extra detail the metadata carries', () => {
    expect(actionLabel({ action: 'key.revoke', metadata: null })).toBe('API key revoked')
    expect(actionLabel({ action: 'admin.login', metadata: { event: 'initial_setup' } })).toBe('Admin account created')
    expect(actionLabel({ action: 'admin.login', metadata: { via: '2fa' } })).toBe('Signed in with two-factor')
    expect(actionLabel({ action: 'future.thing', metadata: null })).toBe('future.thing')
  })

  it('reads a null reset mode as automatic, and says nothing when the mode was not part of the save', () => {
    expect(entryDetails({ action: 'settings.update', metadata: { passwordResetMode: null, resetLinkLifetimeMinutes: 60 } }))
      .toEqual(['Password reset automatic', 'Link lifetime 1 h'])
    expect(entryDetails({ action: 'settings.update', metadata: { resetLinkLifetimeMinutes: 60 } }))
      .toEqual(['Link lifetime 1 h'])
  })

  it('shows chosen metadata fields only, never a dump', () => {
    const details = entryDetails({
      action: 'settings.update',
      metadata: { passwordResetMode: 'manual', resetLinkLifetimeMinutes: 120, token: 'SECRET', password: 'SECRET', userId: 'u1' },
    })
    expect(details).toEqual(['Password reset by a link you hand over', 'Link lifetime 2 h'])
    expect(entryDetails({ action: 'key.create', metadata: { label: 'x'.repeat(500) } })[0]!.length).toBeLessThan(140)
    expect(entryDetails({ action: 'key.invite', metadata: { email: 'a@b.invalid' } })).toEqual(['Invited a@b.invalid'])
  })

  it('turns filters into a query: whole local days, the last day included', () => {
    const q = new URLSearchParams(auditQuery({ action: 'key.create', from: '2026-10-01', to: '2026-10-03' }, 2))
    expect(q.get('limit')).toBe(String(PAGE_SIZE))
    expect(q.get('offset')).toBe(String(2 * PAGE_SIZE))
    expect(q.get('action')).toBe('key.create')
    expect(new Date(q.get('from')!).getTime()).toBe(new Date(2026, 9, 1).getTime())
    expect(new Date(q.get('to')!).getTime()).toBe(new Date(2026, 9, 4).getTime())
    expect(new URLSearchParams(auditQuery({ action: '', from: '', to: '' }, 0)).has('offset')).toBe(false)
  })
})

describe('audit log page', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>

  async function mount(): Promise<void> {
    root = document.createElement('div')
    document.body.appendChild(root)
    app = createApp(AuditPage)
    app.mount(root)
    await settle()
  }

  function setValue(selector: string, value: string): void {
    const el = root.querySelector<HTMLInputElement | HTMLSelectElement>(selector)!
    el.value = value
    // A browser fires both for a date or a select; v-model listens to one of them.
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
  }

  beforeEach(() => {
    get.mockReset()
  })
  afterEach(() => {
    app.unmount()
    root.remove()
  })

  it('lists entries in plain words with time and address', async () => {
    get.mockResolvedValue(json({ logs: [entry(1), entry(2, { action: 'user.delete', metadata: null, ipAddress: null })], hasMore: false }))
    await mount()
    expect(get).toHaveBeenCalledWith(`/admin/audit-logs?limit=${PAGE_SIZE}`)
    const rows = root.querySelectorAll('.audit-row')
    expect(rows).toHaveLength(2)
    expect(rows[0]!.textContent).toContain('API key created')
    expect(rows[0]!.textContent).toContain('Label: Phone 1')
    expect(rows[0]!.textContent).toContain('203.0.113.7')
    expect(rows[1]!.textContent).toContain('Person deleted')
    expect(root.querySelector('time')!.getAttribute('datetime')).toBe('2026-10-01T10:00:00.000Z')
  })

  it('pages with Newer and Older, and stops at the ends', async () => {
    get.mockResolvedValueOnce(json({ logs: [entry(1)], hasMore: true }))
    await mount()
    const [newer, older] = [...root.querySelectorAll<HTMLButtonElement>('.audit-pager button')]
    expect(newer!.disabled).toBe(true)
    expect(older!.disabled).toBe(false)

    get.mockResolvedValueOnce(json({ logs: [entry(2)], hasMore: false }))
    older!.click()
    await settle()
    expect(get).toHaveBeenLastCalledWith(`/admin/audit-logs?limit=${PAGE_SIZE}&offset=${PAGE_SIZE}`)
    expect(root.textContent).toContain(`Entries ${PAGE_SIZE + 1}`)
    expect(root.querySelectorAll<HTMLButtonElement>('.audit-pager button')[1]!.disabled).toBe(true)
  })

  it('applies an action filter from the first page and can clear it', async () => {
    get.mockResolvedValue(json({ logs: [entry(1)], hasMore: false }))
    await mount()
    setValue('#audit-action', 'key.create')
    await settle()
    expect(get.mock.calls.at(-1)![0]).toContain('action=key.create')

    get.mockResolvedValue(json({ logs: [], hasMore: false }))
    setValue('#audit-from', '2026-10-01')
    await settle()
    expect(root.textContent).toContain('Nothing matches those filters')

    ;[...root.querySelectorAll<HTMLButtonElement>('button')].find((b) => b.textContent === 'Clear filters')!.click()
    await settle()
    expect(get.mock.calls.at(-1)![0]).toBe(`/admin/audit-logs?limit=${PAGE_SIZE}`)
  })

  it('does not ask the server for an impossible range', async () => {
    get.mockResolvedValue(json({ logs: [], hasMore: false }))
    await mount()
    get.mockClear()
    setValue('#audit-from', '2026-10-05')
    setValue('#audit-to', '2026-10-01')
    await settle()
    expect(root.querySelector('[role="alert"]')!.textContent).toContain('start date is after')
    expect(get.mock.calls.every(([path]) => !String(path).includes('to='))).toBe(true)
  })

  it('offers a retry when loading fails', async () => {
    get.mockResolvedValueOnce(json({}, false))
    await mount()
    expect(root.querySelector('[role="alert"]')!.textContent).toContain('Could not load the audit log')
    get.mockResolvedValueOnce(json({ logs: [entry(1)], hasMore: false }))
    root.querySelector<HTMLButtonElement>('[role="alert"] button')!.click()
    await settle()
    expect(root.querySelectorAll('.audit-row')).toHaveLength(1)
  })
})
