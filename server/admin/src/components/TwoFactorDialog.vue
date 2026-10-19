<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import AppIcon from './AppIcon.vue'
import BackupCodes from './BackupCodes.vue'
import CopyButton from './CopyButton.vue'
import ModalDialog from './ModalDialog.vue'
import QrCode from './QrCode.vue'
import {
  confirmSetup, disableTwoFactor, groupSecret, regenerateBackupCodes, startSetup,
  type TwoFactorSetup,
} from '../twofactor'

/**
 * One dialog for the three things you can do to admin two-factor: turn it on,
 * replace the backup codes, turn it off. Each ends with the server having
 * signed every admin session out, so the last step always sends you back to
 * the sign-in page. Backup codes live only in this component's state and go
 * when it closes.
 */
const props = defineProps<{ mode: 'setup' | 'regenerate' | 'disable' }>()
const emit = defineEmits<{ close: []; finished: [] }>()

const code = ref('')
const busy = ref(false)
const error = ref('')
const setup = ref<TwoFactorSetup | null>(null)
const setupFailed = ref(false)
const codes = ref<string[]>([])
const saved = ref(false)
const turnedOff = ref(false)

const phase = computed<'enter' | 'codes' | 'off'>(() => (codes.value.length ? 'codes' : turnedOff.value ? 'off' : 'enter'))
const titleId = 'twofactor-dialog-title'
const bodyId = 'twofactor-dialog-body'

const title = computed(() => {
  if (phase.value === 'codes') return 'Save your backup codes'
  if (phase.value === 'off') return 'Two-factor authentication is off'
  if (props.mode === 'setup') return 'Set up two-factor authentication'
  if (props.mode === 'regenerate') return 'New backup codes'
  return 'Turn off two-factor authentication'
})

async function begin(): Promise<void> {
  const result = await startSetup()
  if (result.ok) setup.value = result.value
  else {
    setupFailed.value = true
    error.value = result.error
  }
}

onMounted(() => {
  if (props.mode === 'setup') void begin()
})

async function submit(): Promise<void> {
  if (busy.value || !code.value.trim()) return
  busy.value = true
  error.value = ''
  const value = code.value.trim()
  if (props.mode === 'disable') {
    const result = await disableTwoFactor(value)
    if (result.ok) turnedOff.value = true
    else error.value = result.error
  } else {
    const result = props.mode === 'setup' ? await confirmSetup(value) : await regenerateBackupCodes(value)
    if (result.ok) codes.value = result.value
    else error.value = result.error
  }
  code.value = ''
  busy.value = false
}

function dismiss(): void {
  // Backup codes are shown once; a stray Escape must not lose them.
  if (phase.value === 'enter') emit('close')
}

const submitLabel = computed(() => {
  if (busy.value) return 'Checking…'
  if (props.mode === 'setup') return 'Turn on'
  if (props.mode === 'regenerate') return 'Create new codes'
  return 'Turn off'
})
</script>

<template>
  <ModalDialog :labelledby="titleId" :describedby="bodyId" :persistent="phase !== 'enter'" wide @close="dismiss">
    <h3 :id="titleId">{{ title }}</h3>

    <template v-if="phase === 'enter'">
      <div :id="bodyId">
        <template v-if="mode === 'setup'">
          <p class="hint">
            Scan this code with an authenticator app, then enter the six-digit code it shows.
          </p>
          <p v-if="setupFailed" class="form-error" role="alert">{{ error }}</p>
          <div v-else-if="setup" class="twofactor-setup">
            <QrCode :value="setup.otpauthUri" label="QR code for the authenticator app" />
            <div class="twofactor-secret">
              <span class="label-hint twofactor-secret-label">Or type this key in by hand</span>
              <code class="key-display">{{ groupSecret(setup.secret) }}</code>
              <CopyButton class="btn-secondary btn-sm" :value="setup.secret" label="Copy key" />
            </div>
          </div>
          <div v-else class="skeleton twofactor-skeleton" aria-hidden="true"></div>
        </template>
        <p v-else-if="mode === 'regenerate'" class="hint">
          Your old backup codes stop working. Enter a current code from your authenticator app to confirm.
          Every admin session is signed out afterwards.
        </p>
        <p v-else class="hint">
          Sign-in goes back to the password alone. Enter a code from your authenticator app, or an unused backup code.
          Every admin session is signed out afterwards.
        </p>
      </div>

      <form v-if="mode !== 'setup' || setup" @submit.prevent="submit">
        <div class="form-field">
          <label for="twofactor-code">{{ mode === 'disable' ? 'Authenticator or backup code' : 'Six-digit code' }}</label>
          <input
            id="twofactor-code"
            v-model="code"
            data-autofocus
            :class="mode === 'disable' ? undefined : 'input-code'"
            type="text"
            :inputmode="mode === 'disable' ? 'text' : 'numeric'"
            :maxlength="mode === 'disable' ? 16 : 6"
            :placeholder="mode === 'disable' ? '' : '000000'"
            autocomplete="one-time-code"
            spellcheck="false"
            :aria-invalid="error ? 'true' : undefined"
            :aria-describedby="error ? 'twofactor-error' : undefined"
            required
          />
        </div>
        <p v-if="error" id="twofactor-error" class="form-error" role="alert">{{ error }}</p>
        <div class="modal-actions">
          <button class="btn-ghost" type="button" @click="emit('close')">Cancel</button>
          <button
            :class="mode === 'disable' ? 'btn-danger is-solid' : 'btn-primary'"
            type="submit"
            :disabled="busy || !code.trim()"
          >{{ submitLabel }}</button>
        </div>
      </form>
      <div v-else class="modal-actions">
        <button class="btn-ghost" type="button" @click="emit('close')">Cancel</button>
      </div>
    </template>

    <template v-else-if="phase === 'codes'">
      <div :id="bodyId">
        <p class="hint">
          <template v-if="mode === 'setup'">Two-factor authentication is on. </template>
          Each code works once, in place of an authenticator code. They are shown only now, so store them
          somewhere private.
        </p>
      </div>
      <BackupCodes :codes="codes" />
      <p class="hint twofactor-relogin">Every admin session was signed out. You will sign in again with your new setup.</p>
      <label class="check-row">
        <input v-model="saved" data-autofocus type="checkbox" />
        <span>I have saved these codes</span>
      </label>
      <div class="modal-actions">
        <button class="btn-primary" type="button" :disabled="!saved" @click="emit('finished')">
          Continue to sign in <AppIcon name="arrow" :size="16" />
        </button>
      </div>
    </template>

    <template v-else>
      <div :id="bodyId">
        <p class="hint">Sign-in now asks for the admin password alone. Every admin session was signed out.</p>
      </div>
      <div class="modal-actions">
        <button class="btn-primary" data-autofocus type="button" @click="emit('finished')">
          Continue to sign in <AppIcon name="arrow" :size="16" />
        </button>
      </div>
    </template>
  </ModalDialog>
</template>
