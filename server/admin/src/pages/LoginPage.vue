<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import api from '../api'
import { useToast } from '../useToast'
import AuthFrame from '../components/AuthFrame.vue'

const { show } = useToast()
const router = useRouter()
const password = ref('')
const totpCode = ref('')
const challengeToken = ref('')
const loading = ref(false)

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
      const data = await res.json().catch(() => ({}))
      show(data.error || 'Login failed', 'error')
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
      const data = await res.json().catch(() => ({}))
      show(data.error || 'Invalid code', 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  loading.value = false
}

function backToPassword(): void {
  challengeToken.value = ''
  totpCode.value = ''
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
        <p class="auth-lede">Enter the six-digit code from your authenticator app.</p>
        <form @submit.prevent="submitTotp">
          <div class="form-field">
            <label for="admin-login-totp">Two-factor code</label>
            <input
              id="admin-login-totp"
              v-model="totpCode"
              class="input-code"
              type="text"
              inputmode="numeric"
              pattern="[0-9]{6}"
              maxlength="6"
              autocomplete="one-time-code"
              required
              placeholder="000000"
            />
          </div>
          <button class="btn-primary btn-block" type="submit" :disabled="loading">
            {{ loading ? 'Verifying…' : 'Verify' }}
          </button>
          <button class="btn-ghost btn-block" type="button" @click="backToPassword">
            Use a different password
          </button>
        </form>
      </template>
    </main>
  </AuthFrame>
</template>
