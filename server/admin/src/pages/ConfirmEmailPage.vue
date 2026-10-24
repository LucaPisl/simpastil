<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import api, { apiErrorMessage } from '../api'
import AuthFrame from '../components/AuthFrame.vue'

const route = useRoute()
const router = useRouter()
const token = ref('')
const loading = ref(false)
const ready = ref(false)
const done = ref(false)
const error = ref('')

// The token leaves the address bar as soon as the page has read it.
onMounted(async () => {
  const linkToken = route.query.token
  token.value = typeof linkToken === 'string' ? linkToken : ''
  try {
    await router.replace({ path: route.path })
  } finally {
    ready.value = true
  }
})

async function confirm(): Promise<void> {
  if (!token.value) return
  loading.value = true
  error.value = ''
  try {
    const response = await api.publicPost('/auth/change-email/confirm', { token: token.value })
    if (response.ok) {
      token.value = ''
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
  <AuthFrame eyebrow="Email change">
    <main class="auth-page" aria-labelledby="confirm-email-title">
      <h1 id="confirm-email-title" class="auth-title">Confirm your new email</h1>
      <p v-if="!ready" class="auth-lede" role="status" aria-live="polite">Opening secure link…</p>
      <section v-else-if="done" role="status" aria-live="polite">
        <p class="success-note">Your email is changed. Sign in with the new address next time. Your devices stay signed in.</p>
      </section>
      <section v-else-if="!token" role="alert" class="error-state">
        This link is invalid or has expired. Start the change again in the app, under Settings, Account.
      </section>
      <form v-else @submit.prevent="confirm">
        <p class="auth-lede">Use this address to sign in to Simpastil from now on.</p>
        <p v-if="error" class="error" role="alert" aria-live="polite">{{ error }}</p>
        <button class="btn-primary btn-block" type="submit" :disabled="loading">
          {{ loading ? 'Confirming…' : 'Confirm new email' }}
        </button>
      </form>
    </main>
  </AuthFrame>
</template>
