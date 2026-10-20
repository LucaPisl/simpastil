import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { adminGuard } from './guard'

function jwt(exp: number): string {
  return `h.${btoa(JSON.stringify({ exp }))}.s`
}
const now = () => Math.floor(Date.now() / 1000)

function res(status: number, body: unknown = {}): Response {
  return { ok: status >= 200 && status < 300, status, headers: new Headers(), json: async () => body } as Response
}

describe('adminGuard', () => {
  const fetchMock = vi.fn()
  beforeEach(() => {
    localStorage.clear()
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => vi.unstubAllGlobals())

  it('renews an expired access token with the refresh token instead of signing out', async () => {
    localStorage.setItem('admin_token', jwt(now() - 60))
    localStorage.setItem('admin_refresh_token', 'refresh-1')
    const fresh = jwt(now() + 900)
    fetchMock.mockResolvedValue(res(200, { accessToken: fresh, refreshToken: 'refresh-2' }))

    expect(await adminGuard({ path: '/users' })).toBeUndefined()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]![0]).toBe('/api/v1/admin/auth/refresh')
    expect(localStorage.getItem('admin_token')).toBe(fresh)
    expect(localStorage.getItem('admin_refresh_token')).toBe('refresh-2')
  })

  it('signs out when the refresh is refused', async () => {
    localStorage.setItem('admin_token', jwt(now() - 60))
    localStorage.setItem('admin_refresh_token', 'refresh-1')
    fetchMock.mockResolvedValue(res(401))

    expect(await adminGuard({ path: '/users' })).toBe('/login')
    expect(localStorage.getItem('admin_token')).toBeNull()
    expect(localStorage.getItem('admin_refresh_token')).toBeNull()
  })

  it('signs out when the token expired and there is no refresh token', async () => {
    localStorage.setItem('admin_token', jwt(now() - 60))
    expect(await adminGuard({ path: '/users' })).toBe('/login')
    expect(fetchMock).not.toHaveBeenCalled()
    expect(localStorage.getItem('admin_token')).toBeNull()
  })

  it('keeps the tokens when the server cannot be reached', async () => {
    localStorage.setItem('admin_token', jwt(now() - 60))
    localStorage.setItem('admin_refresh_token', 'refresh-1')
    fetchMock.mockRejectedValue(new Error('offline'))
    expect(await adminGuard({ path: '/users' })).toBe('/login')
    expect(localStorage.getItem('admin_refresh_token')).toBe('refresh-1')
  })

  it('lets a valid token through without any request, and sends visitors without one to login', async () => {
    localStorage.setItem('admin_token', jwt(now() + 900))
    expect(await adminGuard({ path: '/users' })).toBeUndefined()
    expect(fetchMock).not.toHaveBeenCalled()
    localStorage.clear()
    expect(await adminGuard({ path: '/users' })).toBe('/login')
  })

  it('leaves the recovery pages alone and drops an unreadable token', async () => {
    expect(await adminGuard({ path: '/reset-password' })).toBeUndefined()
    localStorage.setItem('admin_token', 'garbage')
    expect(await adminGuard({ path: '/users' })).toBe('/login')
    expect(localStorage.getItem('admin_token')).toBeNull()
  })
})
