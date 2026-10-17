<script setup lang="ts">
import { onMounted, ref } from 'vue'
import AppIcon from './AppIcon.vue'

/**
 * A confirmation that unfolds inside the row it is about, instead of a
 * dialog over the whole page: the thing being removed stays in view while
 * the choice is made. Focus starts on the safe choice; Escape keeps.
 */
const props = defineProps<{
  title: string
  body: string
  confirmLabel: string
  busyLabel: string
  busy?: boolean
}>()
const emit = defineEmits<{ confirm: []; cancel: [] }>()

const keep = ref<HTMLButtonElement>()
onMounted(() => keep.value?.focus({ preventScroll: true }))

function cancel(): void {
  if (!props.busy) emit('cancel')
}
</script>

<template>
  <div class="confirm-strip" role="group" :aria-label="title" @keydown.esc.stop.prevent="cancel">
    <div class="confirm-strip-clip">
      <div class="confirm-strip-inner">
        <span class="confirm-strip-mark" aria-hidden="true"><AppIcon name="unplug" :size="18" /></span>
        <div class="confirm-strip-copy">
          <p class="confirm-strip-title">{{ title }}</p>
          <p class="confirm-strip-body">{{ body }}</p>
        </div>
        <div class="confirm-strip-actions">
          <button ref="keep" class="btn-ghost btn-sm" type="button" :disabled="busy" @click="cancel">Keep</button>
          <button class="btn-danger btn-sm is-solid" type="button" :disabled="busy" @click="emit('confirm')">
            {{ busy ? busyLabel : confirmLabel }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
