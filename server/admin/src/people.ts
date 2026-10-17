import { nextTick, ref } from 'vue'
import type { RouteLocationNormalized, Router } from 'vue-router'
import api from './api'

export interface Person {
  id: string
  email: string
  createdAt: string
}

/**
 * People already seen by this tab, so a person's page can draw its header
 * on the first frame (the shared-element morph needs it there).
 */
const known = ref<Record<string, Person>>({})

/** The whole People list as last loaded, in its order. */
const roster = ref<readonly Person[] | null>(null)

export function rememberPeople(people: readonly Person[], { whole = false } = {}): void {
  const next = { ...known.value }
  for (const p of people) next[p.id] = p
  known.value = next
  if (whole) roster.value = [...people]
}

/**
 * The People list as this tab last saw it, so coming back draws the rows on
 * the first frame (the morph lands on them) while a quiet reload confirms it.
 */
export function lastRoster(): Person[] | null {
  return roster.value ? [...roster.value] : null
}

export function personById(id: string): Person | undefined {
  return known.value[id]
}

/** Looks a person up, asking the server only when this tab hasn't seen them. */
export async function loadPerson(id: string): Promise<Person | undefined> {
  const seen = personById(id)
  if (seen) return seen
  const res = await api.get('/admin/users')
  if (!res.ok) return undefined
  rememberPeople((await res.json()).users, { whole: true })
  return personById(id)
}

/** A view-transition-name for one part of one person; ids are UUIDs. */
export function morphName(part: 'avatar' | 'name', id: string): string {
  return `person-${part}-${id.replace(/[^a-zA-Z0-9_-]/g, '_')}`
}

const PERSON_PAGE = /^\/users\/[^/]+\/(keys|devices)$/

/**
 * Whether going between two routes carries a person across: People into a
 * person's page and back, or between that person's keys and devices.
 */
export function morphsBetween(from: string, to: string): boolean {
  const fromPerson = PERSON_PAGE.test(from)
  const toPerson = PERSON_PAGE.test(to)
  if (fromPerson && toPerson) return from.split('/')[2] === to.split('/')[2]
  return (from === '/users' && toPerson) || (fromPerson && to === '/users')
}

/** True while a morph runs; the page fade stands aside for it. */
export const morphing = ref(false)

type StartViewTransition = (update: () => Promise<void>) => { finished: Promise<void> }

function viewTransitions(): StartViewTransition | null {
  const doc = document as Document & { startViewTransition?: StartViewTransition }
  if (typeof doc.startViewTransition !== 'function') return null
  if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return null
  return doc.startViewTransition.bind(doc)
}

/**
 * Runs person navigations inside a view transition, so the row's avatar and
 * name grow into the person's header (and shrink back on the way out) and
 * the tab capsule slides between keys and devices. Browsers without view
 * transitions keep the ordinary page fade.
 */
export function installPersonMorph(router: Router): void {
  router.beforeResolve((to: RouteLocationNormalized, from: RouteLocationNormalized) => {
    const start = viewTransitions()
    if (!start || !from.matched.length || !morphsBetween(from.path, to.path)) return
    return new Promise<void>((proceed) => {
      morphing.value = true
      const transition = start(async () => {
        const landed = new Promise<void>((done) => {
          const stop = router.afterEach(() => {
            stop()
            done()
          })
        })
        proceed()
        await landed
        // The new page renders on the next ticks (the fade is off).
        await nextTick()
        await nextTick()
      })
      transition.finished.finally(() => {
        morphing.value = false
      })
    })
  })
}
