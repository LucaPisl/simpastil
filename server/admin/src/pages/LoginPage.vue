<script setup lang="ts">
import { nextTick, ref } from 'vue'
import { useRouter } from 'vue-router'
import api, { apiErrorMessage } from '../api'
import { useToast } from '../useToast'
import AuthFrame from '../components/AuthFrame.vue'

const { show } = useToast()
const router = useRouter()
const password = ref('')
const totpCode = ref('')
const challengeToken = ref('')
const useBackup = ref(false)
const loading = ref(false)
const codeInput = ref<HTMLInputElement>()

async function submit(): Promise<void> {
  loading.value = true
  try {
    const res = await fetch('/api/v1/admin/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: password.value }),
    })
    if (res.ok) {
      const d = await res.json()
      if (d.requires2fa) {
        challengeToken.value = d.challengeToken
        loading.value = false
        return
      }
      api._setTokens(d.accessToken, d.refreshToken)
      router.push('/dashboard')
    } else {
      show(await apiErrorMessage(res, 'Login failed'), 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  loading.value = false
}

async function submitTotp(): Promise<void> {
  loading.value = true
  try {
    const res = await fetch('/api/v1/admin/auth/2fa/challenge', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ challengeToken: challengeToken.value, code: totpCode.value }),
    })
    if (res.ok) {
      const d = await res.json()
      api._setTokens(d.accessToken, d.refreshToken)
      router.push('/dashboard')
    } else {
      show(await apiErrorMessage(res, 'Invalid code'), 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  loading.value = false
}

function toggleBackup(): void {
  useBackup.value = !useBackup.value
  totpCode.value = ''
  void nextTick(() => codeInput.value?.focus())
}

function backToPassword(): void {
  challengeToken.value = ''
  totpCode.value = ''
  useBackup.value = false
}
</script>

<template>
  <AuthFrame>
    <main class="auth-page" aria-labelledby="login-title">
      <template v-if="!challengeToken">
        <h1 id="login-title" class="auth-title">Welcome back</h1>
        <p class="auth-lede">Sign in to look after people, devices and keys on this server.</p>
        <form @submit.prevent="submit">
          <div class="form-field">
            <label for="admin-login-password">Admin password</label>
            <input
              id="admin-login-password"
              v-model="password"
              type="password"
              autocomplete="current-password"
              required
            />
          </div>
          <button class="btn-primary btn-block" type="submit" :disabled="loading">
            {{ loading ? 'Signing in…' : 'Sign in' }}
          </button>
        </form>
      </template>
      <template v-else>
        <h1 id="login-title" class="auth-title">One more step</h1>
        <p class="auth-lede">
          {{ useBackup ? 'Enter one of your backup codes. Each works once.' : 'Enter the six-digit code from your authenticator app.' }}
        </p>
        <form @submit.prevent="submitTotp">
          <div class="form-field">
            <label for="admin-login-totp">{{ useBackup ? 'Backup code' : 'Two-factor code' }}</label>
            <input
              id="admin-login-totp"
              ref="codeInput"
              v-model="totpCode"
              :class="useBackup ? undefined : 'input-code'"
              type="text"
              :inputmode="useBackup ? 'text' : 'numeric'"
              :pattern="useBackup ? undefined : '[0-9]{6}'"
              :maxlength="useBackup ? 16 : 6"
              :autocomplete="useBackup ? 'off' : 'one-time-code'"
              :placeholder="useBackup ? undefined : '000000'"
              spellcheck="false"
              required
            />
          </div>
          <button class="btn-primary btn-block" type="submit" :disabled="loading">
            {{ loading ? 'Verifying…' : 'Verify' }}
          </button>
          <button class="btn-ghost btn-block" type="button" @click="toggleBackup">
            {{ useBackup ? 'Use an authenticator code' : 'Use a backup code instead' }}
          </button>
          <button class="btn-ghost btn-block" type="button" @click="backToPassword">
            Use a different password
          </button>
        </form>
      </template>
    </main>
  </AuthFrame>
</template>
