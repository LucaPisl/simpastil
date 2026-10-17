<script setup lang="ts">
import type { IconName } from '../nav'

defineProps<{ name: IconName; size?: number }>()
</script>

<template>
  <svg
    class="icon"
    :width="size ?? 20"
    :height="size ?? 20"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="1.75"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
    focusable="false"
  >
    <template v-if="name === 'overview'">
      <path d="M3 17h18" />
      <path d="M6.5 17a5.5 5.5 0 0 1 11 0" />
      <path d="M12 6.5V5M5.4 9.4l-1-1M18.6 9.4l1-1" />
    </template>
    <template v-else-if="name === 'people'">
      <circle cx="9" cy="8.5" r="3.25" />
      <path d="M3.5 19a5.5 5.5 0 0 1 11 0" />
      <path d="M15.5 5.6a3.25 3.25 0 0 1 0 5.8M17.5 14.2A5.5 5.5 0 0 1 20.5 19" />
    </template>
    <template v-else-if="name === 'key'">
      <circle cx="8" cy="15" r="4" />
      <path d="M10.8 12.2 19 4M16 7l2.5 2.5M14 9l1.8 1.8" />
    </template>
    <template v-else-if="name === 'invite'">
      <rect x="3" y="5.5" width="18" height="13" rx="3" />
      <path d="m4 7.5 8 5.5 8-5.5" />
    </template>
    <template v-else-if="name === 'settings'">
      <path d="M4 7h9M17 7h3M4 17h3M11 17h9" />
      <circle cx="15" cy="7" r="2" />
      <circle cx="9" cy="17" r="2" />
    </template>
    <template v-else-if="name === 'signout'">
      <path d="M14 4.5h3.5a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H14" />
      <path d="M10 8.5 6.5 12l3.5 3.5M6.5 12H15" />
    </template>
    <template v-else-if="name === 'menu'">
      <path d="M4 7.5h16M4 12h16M4 16.5h10" />
    </template>
    <template v-else-if="name === 'close'">
      <path d="M6 6l12 12M18 6 6 18" />
    </template>
    <template v-else-if="name === 'sun'">
      <circle cx="12" cy="12" r="3.75" />
      <path d="M12 3v1.5M12 19.5V21M3 12h1.5M19.5 12H21M5.6 5.6l1.1 1.1M17.3 17.3l1.1 1.1M5.6 18.4l1.1-1.1M17.3 6.7l1.1-1.1" />
    </template>
    <template v-else-if="name === 'moon'">
      <path d="M19.5 14.5A8 8 0 0 1 9.5 4.5a8 8 0 1 0 10 10Z" />
    </template>
    <template v-else-if="name === 'auto'">
      <circle cx="12" cy="12" r="8" />
      <path d="M12 4a8 8 0 0 1 0 16Z" fill="currentColor" stroke="none" />
    </template>
    <template v-else-if="name === 'arrow'">
      <path d="M5 12h14M13 6l6 6-6 6" />
    </template>
    <template v-else-if="name === 'back'">
      <path d="M19 12H5M11 6l-6 6 6 6" />
    </template>
    <template v-else-if="name === 'device'">
      <rect x="7" y="3" width="10" height="18" rx="2.5" />
      <path d="M11 17.5h2" />
    </template>
    <template v-else-if="name === 'plus'">
      <path d="M12 5v14M5 12h14" />
    </template>
    <template v-else-if="name === 'copy'">
      <rect x="8.5" y="8.5" width="11" height="11" rx="2.5" />
      <path d="M15.5 5.5A2 2 0 0 0 13.5 4.5h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 1 1.7" />
    </template>
    <template v-else-if="name === 'check'">
      <path class="icon-check" d="m5 12.5 4.5 4.5L19 7.5" />
    </template>
    <template v-else-if="name === 'unplug'">
      <path d="m10 7.5 1.8-1.8a4 4 0 0 1 5.7 5.7l-1.9 1.8" />
      <path d="m8.4 10.9-1.8 1.8a4 4 0 0 0 5.7 5.7l1.8-1.9" />
      <path d="M4.5 4.5l15 15" />
    </template>
  </svg>
</template>
