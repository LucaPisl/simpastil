import type { RouteLocationNormalized } from 'vue-router'
import api from './api'
import { clearTokens } from './session'

/** True when the access token is a JWT whose expiry has passed; throws when it cannot be read. */
function isExpired(token: string): boolean {
  const payload = JSON.parse(atob(token.split('.')[1]!))
  return Boolean(payload.exp && payload.exp < Date.now() / 1000)
}

/**
 * Sends signed-out visitors to the login page. An expired access token is
 * first renewed with the refresh token (shared with the request layer, so
 * the token is spent once); the session only ends when that fails, and an unreachable server cancels the
 * navigation instead of ending it.
 */
export async function adminGuard(
  to: Pick<RouteLocationNormalized, 'path'>,
  from?: Pick<RouteLocationNormalized, 'matched'>,
): Promise<string | false | undefined> {
  if (to.path === '/setup' || to.path === '/reset-password' || to.path === '/confirm-email' || to.path === '/invite') return
  const token = localStorage.getItem('admin_token')
  if (token && to.path !== '/login') {
    let expired: boolean
    try {
      expired = isExpired(token)
    } catch {
      clearTokens()
      return '/login'
    }
    if (expired) {
      let renewed: boolean
      try {
        renewed = await api._refresh()
      } catch {
        // The server could not be reached, which says nothing about the session:
        // keep the tokens. Someone already in the console stays on their page
        // rather than being thrown to sign-in; a first load has no page to stay on.
        return from && from.matched.length > 0 ? false : '/login'
      }
      if (!renewed) {
        clearTokens()
        return '/login'
      }
    }
  }
  if (!token && to.path !== '/login') return '/login'
  if (to.path === '/login') {
    try {
      const res = await fetch('/api/v1/admin/status')
      if (res.ok) {
        const { configured } = await res.json()
        if (!configured) return '/setup'
      }
    } catch { /* ignore network errors */ }
  }
}
