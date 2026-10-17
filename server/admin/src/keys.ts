/** Helpers for the admin lists: showing API keys, and rows that come and go. */

const SCRAMBLE = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'

export function quietMotion(): boolean {
  return window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false
}

/**
 * One frame of a key decoding into place. At progress `t` the first
 * `t * length` characters are settled; the rest are scrambled. Separators
 * such as `-` and `_` stay put, so the key keeps its shape while it decodes.
 */
export function decodeFrame(value: string, t: number, random: () => number = Math.random): string {
  if (t >= 1) return value
  const settled = Math.floor(Math.max(0, t) * value.length)
  let out = value.slice(0, settled)
  for (let i = settled; i < value.length; i++) {
    const c = value[i]!
    out += /[A-Za-z0-9]/.test(c) ? SCRAMBLE[Math.floor(random() * SCRAMBLE.length)] : c
  }
  return out
}

/** Ids present in `after` but not in `before`: what a reload just added. */
export function addedIds(before: readonly { id: string }[], after: readonly { id: string }[]): string[] {
  const seen = new Set(before.map((k) => k.id))
  return after.filter((k) => !seen.has(k.id)).map((k) => k.id)
}

/** Before a list row leaves, fixes its height so the fold-out can ease from it. */
export function pinRowHeight(el: Element): void {
  const row = el as HTMLElement
  row.style.height = `${row.offsetHeight}px`
}
