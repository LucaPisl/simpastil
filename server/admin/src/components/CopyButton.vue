<script setup lang="ts">
import { onBeforeUnmount, ref } from 'vue'
import AppIcon from './AppIcon.vue'
import { useToast } from '../useToast'

const props = withDefaults(defineProps<{ value: string; label?: string }>(), { label: 'Copy' })

const { show } = useToast()
const copied = ref(false)
let timer: ReturnType<typeof setTimeout> | undefined

async function copy(): Promise<void> {
  try {
    if (!navigator.clipboard) throw new Error('no clipboard')
    await navigator.clipboard.writeText(props.value)
  } catch {
    show('Could not copy. Select the key and copy it by hand.', 'error')
    return
  }
  copied.value = true
  clearTimeout(timer)
  timer = setTimeout(() => (copied.value = false), 1800)
}

onBeforeUnmount(() => clearTimeout(timer))
</script>

<template>
  <!-- Both labels share one grid cell, so the button keeps its width when
       "Copy" turns into "Copied". -->
  <button type="button" class="copy-button" :class="{ 'is-copied': copied }" @click="copy">
    <span class="copy-stack">
      <span class="copy-face" :aria-hidden="copied"><AppIcon name="copy" :size="16" />{{ label }}</span>
      <span class="copy-face copy-done" :aria-hidden="!copied"><AppIcon name="check" :size="16" />Copied</span>
    </span>
    <span class="sr-only" aria-live="polite">{{ copied ? 'Copied' : '' }}</span>
  </button>
</template>
