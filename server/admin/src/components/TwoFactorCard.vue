<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import AppIcon from './AppIcon.vue'
import TwoFactorDialog from './TwoFactorDialog.vue'
import { useToast } from '../useToast'
import { loadStatus, type TwoFactorStatus } from '../twofactor'

const router = useRouter()
const { show } = useToast()
const status = ref<TwoFactorStatus | null>(null)
const loadError = ref(false)
const dialog = ref<'setup' | 'regenerate' | 'disable' | null>(null)

async function load(): Promise<void> {
  loadError.value = false
  const result = await loadStatus()
  if (result.ok) status.value = result.value
  else loadError.value = true
}

onMounted(load)

/** Every 2FA change signs all admin sessions out, so drop the dead tokens and start again. */
function finished(): void {
  dialog.value = null
  localStorage.removeItem('admin_token')
  localStorage.removeItem('admin_refresh_token')
  show('Sign in again to continue', 'success')
  void router.push('/login')
}
</script>

<template>
  <section class="card card-form" aria-labelledby="twofactor-heading">
    <h3 id="twofactor-heading">Two-factor authentication</h3>
    <div v-if="loadError" class="error-state">
      Could not load the two-factor status. <button class="btn-link" type="button" @click="load()">Retry</button>
    </div>
    <div v-else-if="!status" class="skeleton twofactor-skeleton" aria-hidden="true"></div>
    <template v-else-if="!status.available">
      <p class="hint">
        This server takes the admin sign-in from its environment (ADMIN_EMAIL and ADMIN_PASSWORD), so
        two-factor authentication is not available here. Protect that password instead.
      </p>
    </template>
    <template v-else-if="!status.enabled">
      <p class="hint">
        Ask for a code from an authenticator app as well as the password when signing in to this console.
      </p>
      <button class="btn-primary" type="button" @click="dialog = 'setup'">
        <AppIcon name="shield" :size="18" />Set up
      </button>
    </template>
    <template v-else>
      <p class="twofactor-state">
        <span class="status-dot status-active" aria-hidden="true"></span>
        <strong>On</strong>
        <span class="twofactor-count">
          {{ status.backupCodesRemaining }} unused backup {{ status.backupCodesRemaining === 1 ? 'code' : 'codes' }}
        </span>
      </p>
      <p v-if="status.backupCodesRemaining <= 2" class="hint">
        You are running low on backup codes. Create new ones before you lose access to your authenticator app.
      </p>
      <p class="hint">Changing any of this signs every admin session out.</p>
      <div class="twofactor-actions">
        <button class="btn-secondary" type="button" @click="dialog = 'regenerate'">New backup codes</button>
        <button class="btn-danger" type="button" @click="dialog = 'disable'">Turn off</button>
      </div>
    </template>
    <TwoFactorDialog v-if="dialog" :mode="dialog" @close="dialog = null" @finished="finished" />
  </section>
</template>
