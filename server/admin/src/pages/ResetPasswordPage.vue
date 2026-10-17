<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import api, { apiErrorMessage } from '../api'
import AuthFrame from '../components/AuthFrame.vue'

const route = useRoute()
const router = useRouter()
const token = ref('')
const password = ref('')
const loading = ref(false)
const ready = ref(false)
const done = ref(false)
const error = ref('')

onMounted(async () => {
  const linkToken = route.query.token
  token.value = typeof linkToken === 'string' ? linkToken : ''
  try {
    await router.replace({ path: route.path })
  } finally {
    ready.value = true
  }
})

async function submit(): Promise<void> {
  if (!token.value) return
  loading.value = true
  error.value = ''
  try {
    const response = await api.publicPost('/auth/reset-password', {
      token: token.value,
      newPassword: password.value,
    })
    if (response.ok) {
      token.value = ''
      password.value = ''
      done.value = true
    } else {
      error.value = await apiErrorMessage(response)
    }
  } catch {
    error.value = 'Unable to reach the server. Please try again.'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AuthFrame>
    <main class="auth-page" aria-labelledby="reset-title">
      <h1 id="reset-title" class="auth-title">Reset password</h1>
      <p v-if="!ready" class="auth-lede" role="status" aria-live="polite">Opening secure reset link…</p>
      <section v-else-if="done" role="status" aria-live="polite">
        <p class="success-note">Your password has been reset. You can now sign in again.</p>
        <a class="btn-secondary" href="#/login">Return to sign in</a>
      </section>
      <section v-else-if="!token" role="alert" class="error-state">
        This reset link is invalid or has expired. Request a new one from the app.
      </section>
      <form v-else @submit.prevent="submit">
        <div class="form-field">
          <label for="new-password">New password</label>
          <input
            id="new-password"
            v-model="password"
            type="password"
            minlength="10"
            maxlength="72"
            autocomplete="new-password"
            required
          />
        </div>
        <p v-if="error" class="error" role="alert" aria-live="polite">{{ error }}</p>
        <button class="btn-primary btn-block" type="submit" :disabled="loading">
          {{ loading ? 'Resetting…' : 'Reset password' }}
        </button>
      </form>
    </main>
  </AuthFrame>
</template>
