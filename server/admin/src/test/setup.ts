import { Window } from 'happy-dom'

// Node 25+ ships an experimental global `localStorage`/`sessionStorage` that
// shadows happy-dom's and is unusable without --localstorage-file. Install
// happy-dom's own storages explicitly so the suite behaves the same on every
// Node version, with no NODE_OPTIONS.
const storages = new Window()
for (const name of ['localStorage', 'sessionStorage'] as const) {
  Object.defineProperty(globalThis, name, {
    configurable: true,
    enumerable: true,
    value: storages[name],
    writable: true,
  })
}
