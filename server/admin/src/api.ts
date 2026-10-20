/**
 * The refresh in flight, shared by every request that gets a 401 meanwhile.
 * The server rotates refresh tokens and treats a second use of one as theft,
 * which revokes the whole session, so parallel refreshes must never happen.
 */
let refreshInFlight: Promise<boolean> | null = null

const api = {
  _getToken(): string | null {
    return localStorage.getItem('admin_token')
  },

  _setTokens(access: string, refresh: string): void {
    localStorage.setItem('admin_token', access)
    localStorage.setItem('admin_refresh_token', refresh)
  },

  async _fetch(method: string, path: string, body?: unknown, isRetry = false): Promise<Response> {
    const token = this._getToken()
    const res = await fetch(`/api/v1${path}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    })

    if (res.status === 401 && path !== '/admin/auth/login' && path !== '/admin/setup' && !isRetry) {
      // Another request may have refreshed while this one was in flight: then
      // the stored token is newer than the one sent, so just retry with it.
      const current = this._getToken()
      if (current && current !== token) return this._fetch(method, path, body, true)
      if (await this._refresh()) return this._fetch(method, path, body, true)
      localStorage.removeItem('admin_token')
      localStorage.removeItem('admin_refresh_token')
      // Hash-history redirect — avoids circular import with router.ts
      window.location.hash = '#/login'
      throw new Error('Unauthorized')
    }
    return res
  },

  /** Exchanges the refresh token once, however many requests ask at the same time. */
  _refresh(): Promise<boolean> {
    if (!refreshInFlight) {
      // The slot is cleared by a callback that runs after this assignment, even
      // when the exchange settles without waiting on anything.
      const attempt: Promise<boolean> = this._exchangeRefreshToken().finally(() => {
        if (refreshInFlight === attempt) refreshInFlight = null
      })
      refreshInFlight = attempt
    }
    return refreshInFlight
  },

  /**
   * One refresh across all console tabs where the browser has Web Locks: the
   * stored refresh token is read again inside the lock, and when another tab
   * has replaced it meanwhile that tab's tokens are used instead of spending
   * the old token a second time. Without Web Locks it is a plain exchange.
   */
  async _exchangeRefreshToken(): Promise<boolean> {
    const before = localStorage.getItem('admin_refresh_token')
    if (!before) return false
    const exchange = async (): Promise<boolean> => {
      const refreshToken = localStorage.getItem('admin_refresh_token')
      if (!refreshToken) return false
      if (refreshToken !== before) return true
      const r = await fetch('/api/v1/admin/auth/refresh', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refreshToken }),
      })
      if (!r.ok) return false
      const { accessToken, refreshToken: newRefresh } = await r.json()
      this._setTokens(accessToken, newRefresh)
      return true
    }
    const locks = typeof navigator === 'undefined' ? undefined : navigator.locks
    return locks ? locks.request('simpastil-admin-refresh', exchange) : exchange()
  },

  get(path: string): Promise<Response> {
    return this._fetch('GET', path)
  },

  post(path: string, body: unknown): Promise<Response> {
    return this._fetch('POST', path, body)
  },

  put(path: string, body: unknown): Promise<Response> {
    return this._fetch('PUT', path, body)
  },

  publicPost(path: string, body: unknown): Promise<Response> {
    return fetch(`/api/v1${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
  },

  delete(path: string): Promise<Response> {
    return this._fetch('DELETE', path)
  },
}

/** "2 minutes", "45 seconds": how long a rate limit asks the person to wait. */
export function describeWait(seconds: number): string {
  if (seconds >= 60) {
    const minutes = Math.ceil(seconds / 60)
    return `${minutes} ${minutes === 1 ? 'minute' : 'minutes'}`
  }
  const whole = Math.max(1, Math.ceil(seconds))
  return `${whole} ${whole === 1 ? 'second' : 'seconds'}`
}

/** Seconds to wait from the body's `retryAfter` or the Retry-After header, if either is a usable number. */
function retryAfterSeconds(response: Response, body: { retryAfter?: unknown }): number | null {
  const fromBody = body.retryAfter
  if (typeof fromBody === 'number' && Number.isFinite(fromBody) && fromBody > 0) return fromBody
  const header = response.headers?.get?.('Retry-After')
  const parsed = header ? Number(header) : NaN
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null
}

/**
 * The message for a failed response. A 429 reads as a clear "too many
 * attempts" with the wait time when the server gives one, instead of the
 * server's bare "Too Many Requests".
 */
export async function apiErrorMessage(response: Response, fallback = 'Request failed'): Promise<string> {
  const data = await response.json().catch(() => ({})) as {
    error?: string | { message?: unknown };
    retryAfter?: unknown;
  };
  if (response.status === 429) {
    const wait = retryAfterSeconds(response, data)
    return wait === null
      ? 'Too many attempts. Wait a little while and try again.'
      : `Too many attempts. Try again in ${describeWait(wait)}.`
  }
  if (typeof data.error === 'string' && data.error) return data.error;
  if (data.error && typeof data.error === 'object' && typeof data.error.message === 'string' && data.error.message) {
    return data.error.message;
  }
  return fallback;
}

export default api
