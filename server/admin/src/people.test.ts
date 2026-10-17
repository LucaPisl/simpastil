import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, defineComponent, h, nextTick } from 'vue'
import { createMemoryHistory, createRouter, RouterView, type Router } from 'vue-router'
import api from './api'

vi.mock('./api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./api')>()
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

// people.ts keeps a per-tab cache, so each test gets a fresh copy.
async function fresh(): Promise<typeof import('./people')> {
  vi.resetModules()
  return import('./people')
}

const mara = { id: '3f6c1a2e-0b7d', email: 'mara@example.invalid', createdAt: '2026-10-11T10:00:00Z' }
const casey = { id: '8a1d4c33-52e0', email: 'casey@example.invalid', createdAt: '2026-10-04T10:00:00Z' }

beforeEach(() => get.mockReset())

describe('morphsBetween', () => {
  it('carries a person from People into their pages and back', async () => {
    const { morphsBetween } = await fresh()
    expect(morphsBetween('/users', '/users/a/keys')).toBe(true)
    expect(morphsBetween('/users', '/users/a/devices')).toBe(true)
    expect(morphsBetween('/users/a/devices', '/users')).toBe(true)
  })

  it('carries the same person between keys and devices only', async () => {
    const { morphsBetween } = await fresh()
    expect(morphsBetween('/users/a/keys', '/users/a/devices')).toBe(true)
    expect(morphsBetween('/users/a/keys', '/users/b/devices')).toBe(false)
  })

  it('leaves every other navigation to the page fade', async () => {
    const { morphsBetween } = await fresh()
    expect(morphsBetween('/dashboard', '/users')).toBe(false)
    expect(morphsBetween('/users', '/keys')).toBe(false)
    expect(morphsBetween('/users/a/keys', '/settings')).toBe(false)
    expect(morphsBetween('/dashboard', '/users/a/keys')).toBe(false)
  })
})

describe('the people cache', () => {
  it('names morph parts safely per person', async () => {
    const { morphName } = await fresh()
    expect(morphName('avatar', mara.id)).toBe('person-avatar-3f6c1a2e-0b7d')
    expect(morphName('name', 'a b/c')).toBe('person-name-a_b_c')
  })

  it('keeps the whole list only when told it is whole', async () => {
    const { lastRoster, personById, rememberPeople } = await fresh()
    expect(lastRoster()).toBeNull()
    rememberPeople([mara])
    expect(personById(mara.id)).toEqual(mara)
    expect(lastRoster()).toBeNull()
    rememberPeople([mara, casey], { whole: true })
    expect(lastRoster()?.map((p) => p.id)).toEqual([mara.id, casey.id])
  })

  it('asks the server only for a person this tab has not seen', async () => {
    const { loadPerson, rememberPeople } = await fresh()
    get.mockResolvedValue(json({ users: [mara, casey] }))
    expect(await loadPerson(casey.id)).toEqual(casey)
    expect(get).toHaveBeenCalledTimes(1)
    expect(get).toHaveBeenCalledWith('/admin/users')

    get.mockClear()
    rememberPeople([mara])
    expect(await loadPerson(mara.id)).toEqual(mara)
    expect(get).not.toHaveBeenCalled()
  })

  it('gives up quietly when the server refuses', async () => {
    const { loadPerson } = await fresh()
    get.mockResolvedValue(json({}, false))
    expect(await loadPerson(mara.id)).toBeUndefined()
  })
})

describe('installPersonMorph', () => {
  const Page = (name: string) => defineComponent({ render: () => h('div', name) })
  let router: Router
  let started: number
  const doc = document as Document & { startViewTransition?: unknown }

  async function routerAt(path: string): Promise<Router> {
    const people = await fresh()
    router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/users', component: Page('people') },
        { path: '/users/:id/keys', component: Page('keys') },
        { path: '/users/:id/devices', component: Page('devices') },
        { path: '/dashboard', component: Page('overview') },
      ],
    })
    people.installPersonMorph(router)
    await router.push(path)
    await router.isReady()
    const root = document.createElement('div')
    document.body.appendChild(root)
    createApp({ render: () => h(RouterView) }).use(router).mount(root)
    return router
  }

  beforeEach(() => {
    started = 0
    doc.startViewTransition = (update: () => Promise<void>) => {
      started++
      return { finished: update() }
    }
  })

  afterEach(() => {
    delete doc.startViewTransition
    vi.unstubAllGlobals()
    document.body.innerHTML = ''
  })

  it('runs a person navigation inside a view transition and lands on the new page', async () => {
    await routerAt('/users')
    await router.push('/users/a/keys')
    await settle()
    expect(started).toBe(1)
    expect(router.currentRoute.value.path).toBe('/users/a/keys')
    expect(document.body.textContent).toContain('keys')

    await router.push('/users/a/devices')
    await settle()
    expect(started).toBe(2)
    expect(document.body.textContent).toContain('devices')
  })

  it('reports the morph while it runs, so the page fade stands aside', async () => {
    await routerAt('/users')
    const { morphing } = await import('./people')
    let release!: () => void
    doc.startViewTransition = (update: () => Promise<void>) => {
      started++
      const finished = update().then(() => new Promise<void>((done) => (release = done)))
      return { finished }
    }
    await router.push('/users/a/keys')
    await settle()
    expect(morphing.value).toBe(true)
    release()
    await settle()
    expect(morphing.value).toBe(false)
  })

  it('leaves other navigations alone', async () => {
    await routerAt('/dashboard')
    await router.push('/users')
    await settle()
    expect(started).toBe(0)
    expect(document.body.textContent).toContain('people')
  })

  it('does not morph when motion is reduced or the browser lacks view transitions', async () => {
    vi.stubGlobal('matchMedia', (query: string) => ({ matches: query.includes('reduce') }))
    await routerAt('/users')
    await router.push('/users/a/keys')
    await settle()
    expect(started).toBe(0)

    vi.unstubAllGlobals()
    delete doc.startViewTransition
    await router.push('/users')
    await settle()
    expect(router.currentRoute.value.path).toBe('/users')
  })
})
