import api from './api'

export function clearTokens(): void {
  localStorage.removeItem('admin_token')
  localStorage.removeItem('admin_refresh_token')
}

/**
 * Ends this browser's sign-in on the server, then forgets the tokens here.
 * The tokens are forgotten even when the server cannot be reached, so the
 * console always signs out; `serverEnded` says whether the server confirmed it.
 */
export async function signOut(): Promise<{ serverEnded: boolean }> {
  let serverEnded = false
  try {
    const res = await api.post('/admin/auth/logout', {})
    serverEnded = res.ok
  } catch {
    serverEnded = false
  }
  clearTokens()
  return { serverEnded }
}

/** Ends every admin sign-in. The tokens here are only dropped once the server has agreed. */
export async function signOutEverywhere(): Promise<boolean> {
  try {
    const res = await api.post('/admin/auth/logout-all', {})
    if (!res.ok) return false
  } catch {
    return false
  }
  clearTokens()
  return true
}
