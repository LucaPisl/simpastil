<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { theme, setTheme, type ThemeChoice } from './theme'
import { NAV_ITEMS, activeNavIndex } from './nav'
import AppIcon from './components/AppIcon.vue'
import BrandMark from './components/BrandMark.vue'
import ToastHost from './components/ToastHost.vue'
import { morphing } from './people'

const router = useRouter()
const route = useRoute()
const menuOpen = ref(false)
const activeIndex = computed(() => activeNavIndex(route.path))

const THEMES: ReadonlyArray<{ value: ThemeChoice; label: string; icon: 'sun' | 'auto' | 'moon' }> = [
  { value: 'light', label: 'Light', icon: 'sun' },
  { value: 'auto', label: 'Auto', icon: 'auto' },
  { value: 'dark', label: 'Dark', icon: 'moon' },
]

function closeMenu(): void {
  menuOpen.value = false
}

function onKey(e: KeyboardEvent): void {
  if (e.key === 'Escape' && menuOpen.value) closeMenu()
}

watch(() => route.fullPath, closeMenu)
onMounted(() => document.addEventListener('keydown', onKey))
onBeforeUnmount(() => document.removeEventListener('keydown', onKey))

function logout(): void {
  localStorage.removeItem('admin_token')
  localStorage.removeItem('admin_refresh_token')
  router.push('/login')
}
</script>

<template>
  <div class="layout">
    <header class="mobile-topbar">
      <BrandMark :size="26" />
      <button
        class="icon-button"
        type="button"
        :aria-expanded="menuOpen"
        aria-controls="admin-sidebar"
        :aria-label="menuOpen ? 'Close menu' : 'Open menu'"
        @click="menuOpen = !menuOpen"
      >
        <AppIcon :name="menuOpen ? 'close' : 'menu'" :size="22" />
      </button>
    </header>
    <div class="sidebar-overlay" :class="{ open: menuOpen }" @click="closeMenu"></div>
    <nav id="admin-sidebar" class="sidebar" :class="{ open: menuOpen }" aria-label="Admin">
      <div class="sidebar-brand">
        <BrandMark :size="30" />
        <span class="sidebar-badge">Admin</span>
      </div>
      <div class="nav-list" :style="{ '--active': activeIndex }">
        <span v-if="activeIndex >= 0" class="nav-capsule" aria-hidden="true"></span>
        <RouterLink
          v-for="item in NAV_ITEMS"
          :key="item.to"
          class="nav-item"
          :to="item.to"
          :aria-current="activeIndex >= 0 && NAV_ITEMS[activeIndex] === item ? 'page' : undefined"
          :class="{ 'is-active': activeIndex >= 0 && NAV_ITEMS[activeIndex] === item }"
          @click="closeMenu"
        >
          <AppIcon :name="item.icon" />
          <span>{{ item.label }}</span>
        </RouterLink>
      </div>
      <div class="sidebar-footer">
        <div class="segmented" role="group" aria-label="Theme">
          <button
            v-for="t in THEMES"
            :key="t.value"
            type="button"
            class="segmented-option"
            :class="{ active: theme === t.value }"
            :aria-pressed="theme === t.value"
            :title="t.label + ' theme'"
            @click="setTheme(t.value)"
          >
            <AppIcon :name="t.icon" :size="16" />
            <span>{{ t.label }}</span>
          </button>
        </div>
        <button class="nav-item nav-signout" type="button" @click="logout">
          <AppIcon name="signout" />
          <span>Sign out</span>
        </button>
      </div>
    </nav>
    <main class="main">
      <div class="main-inner">
        <RouterView v-slot="{ Component, route: r }">
          <!-- A person morph animates the page itself, so the fade stands aside. -->
          <Transition name="page" :css="!morphing" :mode="morphing ? 'default' : 'out-in'">
            <component :is="Component" :key="r.fullPath" />
          </Transition>
        </RouterView>
      </div>
    </main>
    <ToastHost />
  </div>
</template>
