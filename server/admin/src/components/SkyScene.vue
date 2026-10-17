<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { isDark } from '../theme'
import { orbAt, skyPhase, skyStops, stars } from '../sky'

const props = withDefaults(defineProps<{
  /** Pin the sky to a moment (tests, previews). Omitted: follows the clock. */
  now?: Date
  /** Horizon position as a share of the scene height. */
  horizon?: number
  /** Height of the sun's arc as a share of the sky above the horizon. */
  arc?: number
}>(), { horizon: 0.8, arc: 0.62 })

const clock = ref(new Date())
let timer: ReturnType<typeof setTimeout> | undefined

// Minute-aligned clock that sleeps while the tab is hidden: nothing loops,
// nothing paints between minutes.
function schedule(): void {
  clearTimeout(timer)
  if (props.now || document.hidden) return
  const wait = 60_000 - (Date.now() % 60_000) + 50
  timer = setTimeout(() => {
    clock.value = new Date()
    schedule()
  }, wait)
}

function onVisibility(): void {
  if (!document.hidden) clock.value = new Date()
  schedule()
}

onMounted(() => {
  schedule()
  document.addEventListener('visibilitychange', onVisibility)
})

onBeforeUnmount(() => {
  clearTimeout(timer)
  document.removeEventListener('visibilitychange', onVisibility)
})

const at = computed(() => props.now ?? clock.value)
const phase = computed(() => skyPhase(at.value))
const orb = computed(() => orbAt(at.value))
const starField = stars()

const skyStyle = computed(() => {
  const [top, mid, low] = skyStops(phase.value, isDark.value)
  return {
    background: `linear-gradient(180deg, ${top} 0%, ${mid} 55%, ${low} 100%)`,
    '--horizon': `${props.horizon * 100}%`,
  }
})

const showStars = computed(() =>
  phase.value === 'night' || (isDark.value && phase.value !== 'day'))

const orbStyle = computed(() => {
  const h = props.horizon * 100
  const top = h - orb.value.lift * h * props.arc
  return { left: `${orb.value.x * 100}%`, top: `${top}%` }
})
</script>

<template>
  <div
    class="sky"
    :class="['sky-' + phase, { 'sky-dark': isDark }]"
    :style="skyStyle"
    :data-phase="phase"
  >
    <div class="sky-art" aria-hidden="true">
      <template v-if="showStars">
        <span
          v-for="(s, i) in starField"
          :key="i"
          class="sky-star"
          :style="{
            left: s.x * 100 + '%',
            top: s.y * props.horizon * 100 + '%',
            width: s.r * 2 + 'px',
            height: s.r * 2 + 'px',
            animationDelay: s.delay + 'ms',
          }"
        ></span>
      </template>
      <div class="sky-glow"></div>
      <div class="sky-orb-track" :style="orbStyle">
        <span class="sky-orb" :class="'sky-' + orb.kind"></span>
      </div>
      <svg class="sky-ground" viewBox="0 0 400 60" preserveAspectRatio="none">
        <path class="sky-ground-far" d="M0 22C60 12 120 10 190 17S320 26 400 14V60H0Z" />
        <path class="sky-ground-near" d="M0 34C70 26 140 24 210 30S340 38 400 28V60H0Z" />
      </svg>
    </div>
    <div class="sky-content">
      <slot :phase="phase" />
    </div>
  </div>
</template>
