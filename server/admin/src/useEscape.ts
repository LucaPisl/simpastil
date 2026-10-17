import { onBeforeUnmount, watch, type Ref } from 'vue'

/** Calls `close` on Escape while `open` is truthy, for dialogs over the page. */
export function useEscape(open: Ref<unknown>, close: () => void): void {
  const onKey = (e: KeyboardEvent): void => {
    if (e.key === 'Escape') close()
  }
  watch(
    () => !!open.value,
    (on) => {
      if (on) window.addEventListener('keydown', onKey)
      else window.removeEventListener('keydown', onKey)
    },
    { immediate: true },
  )
  onBeforeUnmount(() => window.removeEventListener('keydown', onKey))
}

/** `v-focus`: focuses an element when it is inserted, e.g. a dialog's first field. */
export const vFocus = { mounted: (el: HTMLElement) => el.focus({ preventScroll: true }) }
