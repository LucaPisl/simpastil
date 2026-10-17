<script setup lang="ts">
defineProps<{ title: string; body?: string }>()
</script>

<template>
  <div class="empty">
    <svg class="empty-art" width="120" height="64" viewBox="0 0 120 64" aria-hidden="true" focusable="false">
      <path d="M0 50c22-8 40-8 60-3s38 5 60-2v19H0Z" class="empty-ground" />
      <circle cx="60" cy="40" r="22" class="empty-halo" />
      <circle cx="60" cy="40" r="9" class="empty-sun" />
    </svg>
    <p class="empty-title">{{ title }}</p>
    <p v-if="body" class="empty-body">{{ body }}</p>
    <div v-if="$slots.default" class="empty-action"><slot /></div>
  </div>
</template>
