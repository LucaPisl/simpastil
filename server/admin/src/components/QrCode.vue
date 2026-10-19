<script setup lang="ts">
import { computed } from 'vue'
import qrcode from 'qrcode-generator'

/**
 * A QR code drawn in the browser as one SVG path, so the setup secret never
 * leaves this page. It sits on a white tile with a quiet zone in both themes,
 * because scanners need dark modules on a light ground.
 */
const props = defineProps<{ value: string; label: string }>()

const QUIET = 4

const model = computed(() => {
  const qr = qrcode(0, 'M')
  qr.addData(props.value)
  qr.make()
  const count = qr.getModuleCount()
  let d = ''
  for (let row = 0; row < count; row += 1) {
    let col = 0
    while (col < count) {
      if (!qr.isDark(row, col)) { col += 1; continue }
      const start = col
      while (col < count && qr.isDark(row, col)) col += 1
      d += `M${start + QUIET} ${row + QUIET}h${col - start}v1h-${col - start}z`
    }
  }
  return { size: count + QUIET * 2, d }
})
</script>

<template>
  <svg
    class="qr-code"
    :viewBox="`0 0 ${model.size} ${model.size}`"
    role="img"
    :aria-label="label"
    shape-rendering="crispEdges"
    focusable="false"
  >
    <rect :width="model.size" :height="model.size" fill="#ffffff" />
    <path :d="model.d" fill="#1b1b1f" />
  </svg>
</template>
