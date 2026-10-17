<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue'
import { decodeFrame, quietMotion } from '../keys'

/** A secret that decodes into place: scrambled characters settle left to right. */
const props = defineProps<{ value: string; inline?: boolean }>()

const shown = ref(props.value)
const settled = ref(props.value.length)
const decoding = ref(false)
let frame = 0

function decode(): void {
  cancelAnimationFrame(frame)
  if (quietMotion()) {
    shown.value = props.value
    settled.value = props.value.length
    decoding.value = false
    return
  }
  const start = performance.now()
  const duration = Math.min(900, 360 + props.value.length * 8)
  let last = -1
  decoding.value = true
  const step = (now: number): void => {
    const t = Math.min(1, (now - start) / duration)
    // About thirty fresh scrambles a second reads as decoding, not flicker.
    const tick = Math.floor((now - start) / 33)
    if (tick !== last || t === 1) {
      last = tick
      shown.value = decodeFrame(props.value, t)
      settled.value = Math.floor(t * props.value.length)
    }
    if (t < 1) frame = requestAnimationFrame(step)
    else decoding.value = false
  }
  shown.value = decodeFrame(props.value, 0)
  settled.value = 0
  frame = requestAnimationFrame(step)
}

watch(() => props.value, decode, { immediate: true })
onBeforeUnmount(() => cancelAnimationFrame(frame))
</script>

<template>
  <code :class="inline ? 'key-display-inline' : 'key-display'" :aria-busy="decoding"
    >{{ shown.slice(0, settled) }}<span v-if="settled < shown.length" class="key-scramble">{{ shown.slice(settled) }}</span></code>
</template>
