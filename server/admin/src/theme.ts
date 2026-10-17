import { ref } from 'vue'

const THEME_KEY = 'simpastil-theme'

export type ThemeChoice = 'light' | 'auto' | 'dark'

function readStored(): ThemeChoice {
  try {
    const v = localStorage.getItem(THEME_KEY)
    return v === 'light' || v === 'dark' ? v : 'auto'
  } catch {
    return 'auto'
  }
}

function systemPrefersDark(): boolean {
  return typeof window.matchMedia === 'function'
    && window.matchMedia('(prefers-color-scheme: dark)').matches
}

export const theme = ref<ThemeChoice>(readStored())

/** The theme actually on screen, after resolving "auto" against the OS. */
export const isDark = ref(false)

export function resolveDark(t: string, prefersDark: boolean): boolean {
  return t === 'dark' || (t !== 'light' && prefersDark)
}

export function applyTheme(t: string): void {
  const dark = resolveDark(t, systemPrefersDark())
  isDark.value = dark
  document.documentElement.classList.toggle('dark', dark)
  // 'light' class suppresses the @media (prefers-color-scheme: dark) CSS fallback
  // so an explicit "Light" selection overrides the OS preference.
  document.documentElement.classList.toggle('light', t === 'light')
}

export function setTheme(t: ThemeChoice): void {
  theme.value = t
  try {
    localStorage.setItem(THEME_KEY, t)
  } catch { /* storage unavailable: the choice lasts for this tab */ }
  applyTheme(t)
}

if (typeof window.matchMedia === 'function') {
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (theme.value === 'auto') applyTheme('auto')
  })
}

applyTheme(theme.value)
