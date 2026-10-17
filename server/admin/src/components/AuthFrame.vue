<script setup lang="ts">
import BrandMark from './BrandMark.vue'
import SkyScene from './SkyScene.vue'
import ToastHost from './ToastHost.vue'
</script>

<template>
  <div class="auth-frame">
    <SkyScene class="auth-sky" :horizon="0.84">
      <div class="auth-sky-inner">
        <BrandMark :size="32" />
        <div class="auth-sky-copy">
          <p class="auth-eyebrow">Server console</p>
          <p class="auth-headline">Care that stays in step, on every phone in the house.</p>
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
