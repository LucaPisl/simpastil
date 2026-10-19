<script setup lang="ts">
import { ref } from 'vue'
import { theme, setTheme } from '../theme'
import api from '../api'
import { useToast } from '../useToast'
import { useRouter } from 'vue-router'
import ModalDialog from '../components/ModalDialog.vue'
import TwoFactorCard from '../components/TwoFactorCard.vue'
import { signOutEverywhere } from '../session'

const { show } = useToast()
const router = useRouter()
const confirmingSignOut = ref(false)
const signingOutEverywhere = ref(false)
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

async function doSignOutEverywhere(): Promise<void> {
  signingOutEverywhere.value = true
  const ended = await signOutEverywhere()
  signingOutEverywhere.value = false
  if (!ended) {
    show('Could not sign out everywhere. Try again.', 'error')
    return
  }
  confirmingSignOut.value = false
  show('Signed out everywhere', 'success')
  await router.push('/login')
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
    <TwoFactorCard />
    <section class="card card-form" aria-labelledby="sessions-heading">
      <h3 id="sessions-heading">Sessions</h3>
      <p class="hint">
        Signs out this browser and every other place you are signed in to this console, including this one.
        Phones and API keys are not affected.
      </p>
      <button class="btn-danger" type="button" @click="confirmingSignOut = true">Sign out everywhere</button>
    </section>
    <ModalDialog
      v-if="confirmingSignOut"
      role="alertdialog"
      labelledby="signout-everywhere-title"
      describedby="signout-everywhere-body"
      @close="confirmingSignOut = false"
    >
      <h3 id="signout-everywhere-title">Sign out everywhere?</h3>
      <p id="signout-everywhere-body" class="hint">
        Every admin session ends and each one has to sign in again. Use this if you think someone else
        has your admin password or a signed-in browser.
      </p>
      <div class="modal-actions">
        <button class="btn-ghost" data-autofocus type="button" @click="confirmingSignOut = false">Cancel</button>
        <button class="btn-danger is-solid" type="button" :disabled="signingOutEverywhere" @click="doSignOutEverywhere">
          {{ signingOutEverywhere ? 'Signing out…' : 'Sign out everywhere' }}
        </button>
      </div>
    </ModalDialog>
  </div>
</template>
