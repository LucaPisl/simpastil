import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp, nextTick } from 'vue'
import { createMemoryHistory, createRouter } from 'vue-router'
import SetupPage from './SetupPage.vue'
import api from '../api'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    default: { post: vi.fn() },
  }
})

const post = vi.mocked(api.post)

function response(body: unknown, ok = false): Response {
  return {
    ok,
    json: async () => body,
  } as Response
}

async function settle(): Promise<void> {
  await nextTick()
  await new Promise((resolve) => setTimeout(resolve, 0))
  await nextTick()
}

describe('SetupPage', () => {
  let root: HTMLDivElement
  let app: ReturnType<typeof createApp>

  beforeEach(async () => {
    post.mockReset()
    root = document.createElement('div')
    document.body.appendChild(root)
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/setup', component: SetupPage },
        { path: '/login', component: { template: '<div>login</div>' } },
      ],
    })
    await router.push('/setup')
    await router.isReady()
    app = createApp(SetupPage)
    app.use(router)
    app.mount(root)
    await settle()
  })

  afterEach(() => {
    app.unmount()
    root.remove()
  })

  function fill(id: string, value: string): void {
    const input = root.querySelector<HTMLInputElement>(`#${id}`)
    expect(input).not.toBeNull()
    input!.value = value
    input!.dispatchEvent(new Event('input', { bubbles: true }))
  }

  function submit(): void {
    root.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
  }

  it('submits the operator proof and exposes accessible labels', async () => {
    post.mockResolvedValue(response({ ok: true }, true))
    fill('admin-email', 'owner@example.invalid')
    fill('admin-password', 'long-enough-password')
    fill('bootstrap-proof', 'proof-value')
    submit()
    await settle()

    expect(post).toHaveBeenCalledWith('/admin/setup', {
      email: 'owner@example.invalid',
      password: 'long-enough-password',
      proof: 'proof-value',
    })
    expect(root.querySelector('label[for="admin-email"]')).not.toBeNull()
    expect(root.querySelector('label[for="admin-password"]')).not.toBeNull()
    expect(root.querySelector('label[for="bootstrap-proof"]')).not.toBeNull()
  })

  it('renders flat and nested API errors and always recovers loading state', async () => {
    post
      .mockResolvedValueOnce(response({ error: 'Invalid bootstrap proof', code: 'ADMIN_BOOTSTRAP_INVALID' }))
      .mockResolvedValueOnce(response({ error: { message: 'Proof has expired' }, code: 'ADMIN_BOOTSTRAP_EXPIRED' }))
      .mockRejectedValueOnce(new Error('network'))

    fill('admin-email', 'owner@example.invalid')
    fill('admin-password', 'long-enough-password')
    fill('bootstrap-proof', 'proof-value')

    submit()
    await settle()
    expect(root.textContent).toContain('Invalid bootstrap proof')
    expect(root.querySelector('button')?.hasAttribute('disabled')).toBe(false)

    submit()
    await settle()
    expect(root.textContent).toContain('Proof has expired')
    expect(root.querySelector('button')?.hasAttribute('disabled')).toBe(false)

    submit()
    await settle()
    expect(root.textContent).toContain('Network error')
    expect(root.querySelector('button')?.hasAttribute('disabled')).toBe(false)
  })
})
