import { ref } from 'vue'

export type ToastType = 'success' | 'error' | 'loading'

interface Toast {
  id: number
  message: string
  type: ToastType
}

const toasts = ref<Toast[]>([])
let nextId = 0

export function useToast() {
  function show(message: string, type: ToastType = 'success', duration = 3000): number {
    const id = nextId++
    toasts.value.push({ id, message, type })
    if (type !== 'loading') {
      setTimeout(() => dismiss(id), duration)
    }
    return id
  }

  function dismiss(id: number) {
    toasts.value = toasts.value.filter(t => t.id !== id)
  }

  return { toasts, show, dismiss }
}
