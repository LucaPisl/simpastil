import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

// Vue's <TransitionGroup> moves rows only when a row's longest transition
// outlasts its longest animation (runtime-dom `hasCSSTransform`). If the
// entrance stagger or a new key's glow runs longer than the move transition,
// rows below a removed one jump instead of springing up. happy-dom does not
// cascade the stylesheet, so this checks the timings in the CSS itself.
const css = readFileSync(resolve(__dirname, 'assets/style.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')

function ms(value: string): number {
  const n = parseFloat(value)
  return value.trim().endsWith('ms') ? n : n * 1000
}

/** Longest delay + duration among the comma-separated parts of a shorthand. */
function longest(shorthand: string): number {
  return Math.max(
    ...shorthand.split(',').map((part) => {
      const times = part.match(/-?[\d.]+m?s\b/g) ?? []
      return (times[0] ? ms(times[0]) : 0) + (times[1] ? ms(times[1]) : 0)
    }),
  )
}

function declarations(selector: RegExp, property: string): string[] {
  const out: string[] = []
  for (const [, sel, body] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (!selector.test(sel!.trim())) continue
    const m = body!.match(new RegExp(`(?:^|;)\\s*${property}\\s*:\\s*([^;]+)`))
    if (m) out.push(m[1]!)
  }
  return out
}

describe('list motion', () => {
  it('a row move outlasts every list-row animation', () => {
    const move = declarations(/^\.list > \.row-move$/, 'transition')
    expect(move).toHaveLength(1)
    const moveTime = longest(move[0]!)

    const rowAnimations = declarations(/^\.list > \.card-row(\.[\w-]+)?$/, 'animation')
    const staggers = declarations(/^\.list > \.card-row:nth-child/, 'animation-delay').map(ms)
    expect(rowAnimations.length).toBeGreaterThan(0)
    const animationTime = Math.max(...rowAnimations.map(longest)) + Math.max(0, ...staggers)

    expect(moveTime).toBeGreaterThan(animationTime)
  })

  it('a row entrance does not hold its end frame over the move transform', () => {
    for (const animation of declarations(/^\.list > \.card-row(\.[\w-]+)?$/, 'animation')) {
      expect(animation).not.toMatch(/\b(both|forwards)\b/)
    }
  })
})
