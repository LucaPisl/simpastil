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
      const refreshToken = localStorage.getItem('admin_refresh_token')
      if (refreshToken) {
        const r = await fetch('/api/v1/admin/auth/refresh', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ refreshToken }),
        })
        if (r.ok) {
          const { accessToken, refreshToken: newRefresh } = await r.json()
          this._setTokens(accessToken, newRefresh)
          return this._fetch(method, path, body, true)
        }
      }
      localStorage.removeItem('admin_token')
      localStorage.removeItem('admin_refresh_token')
      // Hash-history redirect — avoids circular import with router.ts
      window.location.hash = '#/login'
      throw new Error('Unauthorized')
    }
    return res
  },

  get(path: string): Promise<Response> {
    return this._fetch('GET', path)
  },

  post(path: string, body: unknown): Promise<Response> {
    return this._fetch('POST', path, body)
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

export async function apiErrorMessage(response: Response): Promise<string> {
  const data = await response.json().catch(() => ({})) as {
    error?: string | { message?: unknown };
  };
  if (typeof data.error === 'string' && data.error) return data.error;
  if (data.error && typeof data.error === 'object' && typeof data.error.message === 'string' && data.error.message) {
    return data.error.message;
  }
  return 'Request failed';
}

export default api
