import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import api, { apiErrorMessage, describeWait, REFRESH_TIMEOUT_MS } from './api'

function res(status: number, body: unknown = {}, headers: Record<string, string> = {}): Response {
  return { ok: status >= 200 && status < 300, status, headers: new Headers(headers), json: async () => body } as Response
}

describe('api refresh', () => {
  const fetchMock = vi.fn()
  let refreshCalls: number
  let releaseRefresh: () => void

  beforeEach(() => {
    localStorage.clear()
    localStorage.setItem('admin_token', 'old-access')
    localStorage.setItem('admin_refresh_token', 'old-refresh')
    window.location.hash = '#/keys'
    refreshCalls = 0
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => vi.unstubAllGlobals())

  function authHeader(init: RequestInit): string | undefined {
    return (init.headers as Record<string, string>)['Authorization']
  }

  it('shares one refresh between parallel 401s and keeps the admin signed in', async () => {
    const gate = new Promise<void>((resolve) => { releaseRefresh = resolve })
    fetchMock.mockImplementation(async (url: string, init: RequestInit) => {
      if (url === '/api/v1/admin/auth/refresh') {
        refreshCalls += 1
        // Reuse detection: a second use of the same refresh token ends the session.
        if (refreshCalls > 1) return res(401, { error: 'reuse' })
        await gate
        return res(200, { accessToken: 'new-access', refreshToken: 'new-refresh' })
      }
      return authHeader(init) === 'Bearer new-access' ? res(200, { ok: url }) : res(401)
    })

    const calls = [api.get('/admin/users'), api.get('/admin/keys'), api.get('/admin/audit')]
    await new Promise((resolve) => setTimeout(resolve, 0))
    releaseRefresh()
    const results = await Promise.all(calls)

    expect(results.map((r) => r.status)).toEqual([200, 200, 200])
    expect(refreshCalls).toBe(1)
    expect(localStorage.getItem('admin_token')).toBe('new-access')
    expect(localStorage.getItem('admin_refresh_token')).toBe('new-refresh')
    expect(window.location.hash).toBe('#/keys')
  })

  it('retries with the newer token instead of refreshing again after another request already did', async () => {
    fetchMock.mockImplementation(async (url: string, init: RequestInit) => {
      if (url === '/api/v1/admin/auth/refresh') {
        refreshCalls += 1
        return res(200, { accessToken: 'new-access', refreshToken: 'new-refresh' })
      }
      if (authHeader(init) === 'Bearer old-access') {
        // A slow 401 that lands after a sibling request has already refreshed.
        localStorage.setItem('admin_token', 'new-access')
        return res(401)
      }
      return res(200)
    })
    expect((await api.get('/admin/users')).status).toBe(200)
    expect(refreshCalls).toBe(0)
  })

  it('signs out once when the refresh is refused', async () => {
    fetchMock.mockImplementation(async (url: string) => {
      if (url === '/api/v1/admin/auth/refresh') {
        refreshCalls += 1
        return res(401)
      }
      return res(401)
    })
    const results = await Promise.allSettled([api.get('/admin/users'), api.get('/admin/keys')])
    expect(results.every((r) => r.status === 'rejected')).toBe(true)
    expect(refreshCalls).toBe(1)
    expect(localStorage.getItem('admin_token')).toBeNull()
    expect(localStorage.getItem('admin_refresh_token')).toBeNull()
    expect(window.location.hash).toBe('#/login')
  })

  it('refreshes later even if an earlier 401 found no refresh token to use', async () => {
    localStorage.removeItem('admin_refresh_token')
    fetchMock.mockImplementation(async (url: string, init: RequestInit) => {
      if (url === '/api/v1/admin/auth/refresh') {
        refreshCalls += 1
        return res(200, { accessToken: 'new-access', refreshToken: 'new-refresh' })
      }
      return authHeader(init) === 'Bearer new-access' ? res(200) : res(401)
    })
    await expect(api.get('/admin/users')).rejects.toThrow('Unauthorized')
    expect(refreshCalls).toBe(0)

    localStorage.setItem('admin_token', 'expired')
    localStorage.setItem('admin_refresh_token', 'valid-refresh')
    expect((await api.get('/admin/users')).status).toBe(200)
    expect(refreshCalls).toBe(1)
  })

  it('can refresh again later, after the first refresh finished', async () => {
    let token = 1
    fetchMock.mockImplementation(async (url: string, init: RequestInit) => {
      if (url === '/api/v1/admin/auth/refresh') {
        refreshCalls += 1
        token += 1
        return res(200, { accessToken: `a${token}`, refreshToken: `r${token}` })
      }
      return authHeader(init) === `Bearer a${token}` ? res(200) : res(401)
    })
    expect((await api.get('/x')).status).toBe(200)
    localStorage.setItem('admin_token', 'expired-again')
    expect((await api.get('/y')).status).toBe(200)
    expect(refreshCalls).toBe(2)
  })
})

describe('apiErrorMessage for a rate limit', () => {
  it('uses the wait time from the body', async () => {
    expect(await apiErrorMessage(res(429, { error: 'Too Many Requests', retryAfter: 90 })))
      .toBe('Too many attempts. Try again in 2 minutes.')
  })

  it('falls back to the Retry-After header', async () => {
    expect(await apiErrorMessage(res(429, { error: 'Too Many Requests' }, { 'Retry-After': '30' })))
      .toBe('Too many attempts. Try again in 30 seconds.')
  })

  it('still reads clearly when no wait time is given', async () => {
    expect(await apiErrorMessage(res(429, { error: 'Too Many Requests' })))
      .toBe('Too many attempts. Wait a little while and try again.')
  })

  it('formats waits in the singular and rounds up', () => {
    expect(describeWait(1)).toBe('1 second')
    expect(describeWait(0.2)).toBe('1 second')
    expect(describeWait(60)).toBe('1 minute')
    expect(describeWait(61)).toBe('2 minutes')
  })
})

describe('api refresh across tabs', () => {
  const fetchMock = vi.fn()
  const originalLocks = Object.getOwnPropertyDescriptor(navigator, 'locks')

  beforeEach(() => {
    localStorage.clear()
    localStorage.setItem('admin_token', 'old-access')
    localStorage.setItem('admin_refresh_token', 'old-refresh')
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => {
    vi.unstubAllGlobals()
    if (originalLocks) Object.defineProperty(navigator, 'locks', originalLocks)
    else delete (navigator as unknown as Record<string, unknown>)['locks']
  })

  function setLocks(request: (name: string, cb: () => Promise<boolean>) => Promise<boolean>): void {
    Object.defineProperty(navigator, 'locks', { configurable: true, value: { request } })
  }

  function server(onRefresh: () => void): void {
    fetchMock.mockImplementation(async (url: string, init: RequestInit) => {
      if (url === '/api/v1/admin/auth/refresh') {
        onRefresh()
        return res(200, { accessToken: 'new-access', refreshToken: 'new-refresh' })
      }
      const auth = (init.headers as Record<string, string>)['Authorization']
      return auth === 'Bearer new-access' ? res(200) : res(401)
    })
  }

  it('refreshes inside the shared lock', async () => {
    const names: string[] = []
    setLocks(async (name, cb) => { names.push(name); return cb() })
    let calls = 0
    server(() => { calls += 1 })
    expect((await api.get('/admin/users')).status).toBe(200)
    expect(names).toEqual(['simpastil-admin-refresh'])
    expect(calls).toBe(1)
  })

  it('uses the tokens another tab stored while waiting for the lock, without spending the old one', async () => {
    setLocks(async (_name, cb) => {
      localStorage.setItem('admin_token', 'new-access')
      localStorage.setItem('admin_refresh_token', 'other-tab-refresh')
      return cb()
    })
    let calls = 0
    server(() => { calls += 1 })
    expect((await api.get('/admin/users')).status).toBe(200)
    expect(calls).toBe(0)
    expect(localStorage.getItem('admin_refresh_token')).toBe('other-tab-refresh')
  })

  it('still refreshes where Web Locks do not exist', async () => {
    delete (navigator as unknown as Record<string, unknown>)['locks']
    Object.defineProperty(navigator, 'locks', { configurable: true, value: undefined })
    let calls = 0
    server(() => { calls += 1 })
    expect((await api.get('/admin/users')).status).toBe(200)
    expect(calls).toBe(1)
  })

  it('falls back to a plain exchange when the lock cannot be taken', async () => {
    setLocks(async () => { throw new DOMException('denied', 'SecurityError') })
    let calls = 0
    server(() => { calls += 1 })
    expect((await api.get('/admin/users')).status).toBe(200)
    expect(calls).toBe(1)
  })

  it('does not retry outside the lock when the exchange inside it failed', async () => {
    setLocks(async (_name, cb) => cb())
    let calls = 0
    fetchMock.mockImplementation(async (url: string) => {
      if (url === '/api/v1/admin/auth/refresh') {
        calls += 1
        throw new TypeError('network down')
      }
      return res(401)
    })
    await expect(api.get('/admin/users')).rejects.toThrow('network down')
    expect(calls).toBe(1)
  })

  it('gives up on a hung refresh request so the lock is released', async () => {
    vi.useFakeTimers()
    try {
      let aborted = false
      fetchMock.mockImplementation((url: string, init: RequestInit) => {
        if (url !== '/api/v1/admin/auth/refresh') return Promise.resolve(res(401))
        return new Promise((_resolve, reject) => {
          init.signal!.addEventListener('abort', () => {
            aborted = true
            reject(new DOMException('aborted', 'AbortError'))
          })
        })
      })
      let released = false
      setLocks(async (_name, cb) => {
        try { return await cb() } finally { released = true }
      })
      const outcome = api.get('/admin/users').then(() => 'ok', (e: Error) => e.name)
      await vi.advanceTimersByTimeAsync(REFRESH_TIMEOUT_MS - 1)
      expect(aborted).toBe(false)
      await vi.advanceTimersByTimeAsync(1)
      expect(aborted).toBe(true)
      expect(await outcome).toBe('AbortError')
      expect(released).toBe(true)
      // The session is untouched: a timeout is not a refusal.
      expect(localStorage.getItem('admin_refresh_token')).toBe('old-refresh')
    } finally {
      vi.useRealTimers()
    }
  })
})
