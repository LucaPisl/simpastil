<script setup lang="ts">
import { ref } from 'vue'
import { theme, setTheme } from '../theme'
import api from '../api'
import { useToast } from '../useToast'

const { show } = useToast()
const newPass = ref('')
const changingPassword = ref(false)

async function changePassword(): Promise<void> {
  changingPassword.value = true
  try {
    const res = await api.post('/admin/auth/change-password', { newPassword: newPass.value })
    if (res.ok) {
      show('Password updated', 'success')
    } else {
      const data = await res.json().catch(() => ({}))
      show(data.error || 'Failed to update password', 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  newPass.value = ''
  changingPassword.value = false
}
</script>

<template>
  <div>
    <header class="page-header">
      <div>
        <h1 class="page-title">Settings</h1>
        <p class="page-lede">How this console looks, and how you sign in to it.</p>
      </div>
    </header>
    <div class="card card-form">
      <h3>Appearance</h3>
      <p class="hint">Auto follows your system and changes with it.</p>
      <div class="segmented segmented-wide" role="group" aria-label="Theme">
        <button type="button" :class="['segmented-option', { active: theme === 'light' }]" :aria-pressed="theme === 'light'" @click="setTheme('light')">Light</button>
        <button type="button" :class="['segmented-option', { active: theme === 'auto' }]" :aria-pressed="theme === 'auto'" @click="setTheme('auto')">Auto</button>
        <button type="button" :class="['segmented-option', { active: theme === 'dark' }]" :aria-pressed="theme === 'dark'" @click="setTheme('dark')">Dark</button>
      </div>
    </div>
    <div class="card card-form">
      <h3>Change password</h3>
      <form @submit.prevent="changePassword">
        <div class="form-field">
          <label for="settings-new-password">New password <span class="label-hint">at least 10 characters</span></label>
          <input id="settings-new-password" v-model="newPass" autocomplete="new-password" type="password" minlength="10" required />
        </div>
        <button class="btn-primary" type="submit" :disabled="changingPassword">
          {{ changingPassword ? 'Updating…' : 'Update password' }}
        </button>
      </form>
    </div>
  </div>
</template>
