<script setup lang="ts">
import { useToast } from '../useToast'

const { toasts } = useToast()
</script>

<template>
  <div class="toast-container" role="status" aria-live="polite">
    <TransitionGroup name="toast">
      <div
        v-for="t in toasts"
        :key="t.id"
        class="toast"
        :class="'toast-' + t.type"
      >
        <span class="toast-dot" aria-hidden="true"></span>
        <span>{{ t.message }}</span>
      </div>
    </TransitionGroup>
  </div>
</template>
