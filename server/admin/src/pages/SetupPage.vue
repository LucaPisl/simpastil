<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import api, { apiErrorMessage } from '../api'
import { useToast } from '../useToast'
import AuthFrame from '../components/AuthFrame.vue'

const { show } = useToast()
const router = useRouter()
const email = ref('')
const password = ref('')
const proof = ref('')
const loading = ref(false)

async function submit(): Promise<void> {
  loading.value = true
  try {
    const res = await api.post('/admin/setup', {
      email: email.value,
      password: password.value,
      proof: proof.value,
    })
    if (res.ok) {
      show('Account created! Redirecting...', 'success')
      router.push('/login')
    } else {
      show(await apiErrorMessage(res), 'error')
    }
  } catch {
    show('Network error', 'error')
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AuthFrame>
    <main class="auth-page" aria-labelledby="setup-title">
      <h1 id="setup-title" class="auth-title">Set up this server</h1>
      <p class="auth-lede">Create the administrator account. You will need the one-time proof printed by the provision service.</p>
      <form @submit.prevent="submit">
        <div class="form-field">
          <label for="admin-email">Admin email</label>
          <input id="admin-email" v-model="email" type="email" autocomplete="email" required />
        </div>
        <div class="form-field">
          <label for="admin-password">Password <span class="label-hint">at least 10 characters</span></label>
          <input id="admin-password" v-model="password" type="password" autocomplete="new-password" minlength="10" required />
        </div>
        <div class="form-field">
          <label for="bootstrap-proof">Operator bootstrap proof</label>
          <input
            id="bootstrap-proof"
            v-model="proof"
            type="text"
            autocomplete="off"
            autocapitalize="none"
            spellcheck="false"
            required
          />
        </div>
        <button class="btn-primary btn-block" type="submit" :disabled="loading">
          {{ loading ? 'Creating…' : 'Create account' }}
        </button>
      </form>
    </main>
  </AuthFrame>
</template>
