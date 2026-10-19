<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'

/**
 * The shell for the console's dialogs. It names itself for assistive tech,
 * moves focus in (to the field marked `data-autofocus`, else the first
 * control), keeps Tab inside, closes on Escape or a click outside unless the
 * dialog is `persistent`, and hands focus back to whatever opened it.
 */
const props = withDefaults(defineProps<{
  /** Id of the element that titles the dialog. */
  labelledby: string
  /** Id of an element that describes it, if any. */
  describedby?: string
  role?: 'dialog' | 'alertdialog'
  /** Escape and a click outside do nothing: for something that must be read once. */
  persistent?: boolean
  wide?: boolean
}>(), { role: 'dialog', describedby: undefined })
const emit = defineEmits<{ close: [] }>()

const dialog = ref<HTMLElement>()
let opener: HTMLElement | null = null

const FOCUSABLE = [
  'a[href]', 'button:not([disabled])', 'input:not([disabled])', 'select:not([disabled])',
  'textarea:not([disabled])', '[tabindex]:not([tabindex="-1"])',
].join(',')

function focusable(): HTMLElement[] {
  return Array.from(dialog.value?.querySelectorAll<HTMLElement>(FOCUSABLE) ?? [])
    .filter((el) => !el.hasAttribute('hidden') && el.getAttribute('aria-hidden') !== 'true')
}

function close(): void {
  if (!props.persistent) emit('close')
}

function onKeydown(e: KeyboardEvent): void {
  if (e.key === 'Escape') {
    e.stopPropagation()
    close()
    return
  }
  if (e.key !== 'Tab') return
  const items = focusable()
  if (!items.length) {
    e.preventDefault()
    dialog.value?.focus()
    return
  }
  const first = items[0]!
  const last = items[items.length - 1]!
  const active = document.activeElement
  if (e.shiftKey && (active === first || active === dialog.value)) {
    e.preventDefault()
    last.focus()
  } else if (!e.shiftKey && active === last) {
    e.preventDefault()
    first.focus()
  }
}

onMounted(() => {
  opener = document.activeElement instanceof HTMLElement ? document.activeElement : null
  const target = dialog.value?.querySelector<HTMLElement>('[data-autofocus]') ?? focusable()[0] ?? dialog.value
  target?.focus({ preventScroll: true })
  document.body.style.overflow = 'hidden'
})

onBeforeUnmount(() => {
  document.body.style.overflow = ''
  if (opener?.isConnected) opener.focus({ preventScroll: true })
})
</script>

<template>
  <div class="modal-overlay" @click.self="close">
    <div
      ref="dialog"
      class="modal"
      :class="{ 'modal-wide': wide }"
      :role="role"
      aria-modal="true"
      :aria-labelledby="labelledby"
      :aria-describedby="describedby"
      tabindex="-1"
      @keydown="onKeydown"
    >
      <slot />
    </div>
  </div>
</template>
