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
const accepted = ref<{ serverUrl: string; apiKey: string } | null>(null)
const error = ref('')
const copied = ref(false)

onMounted(async () => {
  const linkToken = route.query.token
  token.value = typeof linkToken === 'string' ? linkToken : ''
  try {
    await router.replace({ path: route.path })
  } finally {
    ready.value = true
  }
})

async function accept(): Promise<void> {
  if (!token.value) return
  loading.value = true
  error.value = ''
  try {
    const response = await api.publicPost('/auth/invite/accept', { token: token.value })
    if (!response.ok) {
      error.value = await apiErrorMessage(response)
      return
    }
    accepted.value = await response.json() as { serverUrl: string; apiKey: string }
    token.value = ''
  } catch {
    error.value = 'Unable to reach the server. Please try again.'
  } finally {
    loading.value = false
  }
}

async function copyKey(): Promise<void> {
  if (!accepted.value) return
  try {
    await navigator.clipboard.writeText(accepted.value.apiKey)
    copied.value = true
  } catch {
    error.value = 'Copy was unavailable. Select and copy the key manually.'
  }
}
</script>

<template>
  <AuthFrame eyebrow="Invitation">
    <main class="auth-page" aria-labelledby="invite-title">
      <h1 id="invite-title" class="auth-title">Accept invitation</h1>
      <p v-if="!ready" class="auth-lede" role="status" aria-live="polite">Opening secure invitation…</p>
      <section v-else-if="accepted" role="status" aria-live="polite">
        <p class="success-note">Your invitation is ready. Save these connection details now.</p>
        <div class="form-field">
          <label for="server-url">Server URL</label>
          <input id="server-url" :value="accepted.serverUrl" readonly />
        </div>
        <div class="form-field">
          <label for="invite-key">One-time API key</label>
          <textarea id="invite-key" class="key-display" :value="accepted.apiKey" rows="3" readonly />
        </div>
        <button class="btn-secondary" type="button" @click="copyKey">
          {{ copied ? 'Copied' : 'Copy API key' }}
        </button>
      </section>
      <section v-else-if="!token" role="alert" class="error-state">
        This invitation is invalid or has expired. Ask the administrator for a new invitation.
      </section>
      <section v-else>
        <p class="auth-lede">Accepting this invitation will reveal your API key once.</p>
        <p v-if="error" class="error" role="alert" aria-live="polite">{{ error }}</p>
        <button class="btn-primary" type="button" :disabled="loading" @click="accept">
          {{ loading ? 'Accepting…' : 'Accept invitation' }}
        </button>
      </section>
    </main>
  </AuthFrame>
</template>
