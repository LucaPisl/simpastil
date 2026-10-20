<script setup lang="ts">
import BrandMark from './BrandMark.vue'
import SkyScene from './SkyScene.vue'
import ToastHost from './ToastHost.vue'

// The left panel names where the person is. Pages for people who are not
// administrators (a password reset, accepting an invitation) pass their own
// label. The headline stays device-neutral because those pages are for app
// users on phones and tablets.
withDefaults(defineProps<{ eyebrow?: string }>(), { eyebrow: 'Server console' })
</script>

<template>
  <div class="auth-frame">
    <SkyScene class="auth-sky" :horizon="0.84">
      <div class="auth-sky-inner">
        <BrandMark :size="32" />
        <div class="auth-sky-copy">
          <p class="auth-eyebrow">{{ eyebrow }}</p>
          <p class="auth-headline">Care that stays in step, on every device in the house.</p>
        </div>
      </div>
    </SkyScene>
    <div class="auth-panel">
      <div class="auth-card">
        <slot />
      </div>
    </div>
    <ToastHost />
  </div>
</template>
