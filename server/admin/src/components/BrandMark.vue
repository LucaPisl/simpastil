<script setup lang="ts">
withDefaults(defineProps<{ size?: number; wordmark?: boolean }>(), { size: 28, wordmark: true })
</script>

<template>
  <span class="brand-mark">
    <svg :width="size" :height="size" viewBox="0 0 32 32" aria-hidden="true" focusable="false">
      <g transform="rotate(-38 16 16)">
        <rect x="4" y="10.5" width="24" height="11" rx="5.5" class="brand-capsule-light" />
        <path d="M9.5 10.5H16v11H9.5a5.5 5.5 0 0 1 0-11Z" class="brand-capsule-solid" />
      </g>
    </svg>
    <span v-if="wordmark" class="brand-word">Simpastil</span>
  </span>
</template>
