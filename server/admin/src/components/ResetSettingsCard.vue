<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useToast } from '../useToast'
import {
  lifetimeToMinutes, loadSettings, saveSettings, splitLifetime,
  type LifetimeUnit, type ResetModeChoice, type ResetSettings,
} from '../settings'

const { show } = useToast()
const settings = ref<ResetSettings | null>(null)
const loadError = ref(false)
const mode = ref<'auto' | 'email' | 'manual'>('auto')
const amount = ref('')
const unit = ref<LifetimeUnit>('minutes')
const saving = ref(false)
const saveError = ref('')
/** Shown only after a failed attempt, so a half-typed number is not scolded. */
const tried = ref(false)

const smtp = computed(() => settings.value?.smtpConfigured ?? false)
const parsed = computed(() => lifetimeToMinutes(amount.value, unit.value))
const lifetimeError = computed(() => (tried.value && !parsed.value.ok ? parsed.value.error : ''))

function fill(next: ResetSettings): void {
  settings.value = next
  mode.value = next.passwordResetMode ?? 'auto'
  const { value, unit: u } = splitLifetime(next.resetLinkLifetimeMinutes)
  amount.value = String(value)
  unit.value = u
}

async function load(): Promise<void> {
  loadError.value = false
  const result = await loadSettings()
  if (result) fill(result)
  else loadError.value = true
}

onMounted(load)

function choice(): ResetModeChoice {
  return mode.value === 'auto' ? null : mode.value
}

async function save(): Promise<void> {
  tried.value = true
  saveError.value = ''
  const lifetime = parsed.value
  if (!lifetime.ok) return
  saving.value = true
  const result = await saveSettings({ passwordResetMode: choice(), resetLinkLifetimeMinutes: lifetime.minutes })
  saving.value = false
  if (result.ok) {
    fill(result.settings)
    tried.value = false
    show('Password reset settings saved', 'success')
    return
  }
  saveError.value = result.error
}
</script>

<template>
  <section class="card card-form" aria-labelledby="reset-heading">
    <h3 id="reset-heading">Password reset</h3>
    <div v-if="loadError" class="error-state">
      Could not load these settings. <button class="btn-link" type="button" @click="load()">Retry</button>
    </div>
    <div v-else-if="!settings" class="skeleton reset-skeleton" aria-hidden="true"></div>
    <form v-else novalidate @submit.prevent="save">
      <p class="hint">How a person who forgot their password gets back in.</p>
      <fieldset class="choice-list">
        <legend class="sr-only">How passwords are reset</legend>
        <label class="choice" :class="{ 'is-checked': mode === 'auto' }">
          <input v-model="mode" type="radio" name="reset-mode" value="auto" />
          <span class="choice-text">
            <strong>Automatic</strong>
            <small>
              {{ smtp ? 'Email a link, because this server can send email.' : 'Hand links over yourself, because this server cannot send email.' }}
            </small>
          </span>
        </label>
        <label class="choice" :class="{ 'is-checked': mode === 'email', 'is-off': !smtp }">
          <input v-model="mode" type="radio" name="reset-mode" value="email" :disabled="!smtp" aria-describedby="reset-email-note" />
          <span class="choice-text">
            <strong>Email</strong>
            <small id="reset-email-note">
              {{ smtp
                ? 'The app asks for a reset and the server mails the link.'
                : 'Needs email sending. Set SMTP_HOST on the server first (see DEPLOYMENT.md).' }}
            </small>
          </span>
        </label>
        <label class="choice" :class="{ 'is-checked': mode === 'manual' }">
          <input v-model="mode" type="radio" name="reset-mode" value="manual" />
          <span class="choice-text">
            <strong>Manual</strong>
            <small>
              You create a link for a person and give it to them yourself. Email invitations are switched off; create API keys instead.
            </small>
          </span>
        </label>
      </fieldset>

      <div class="form-field lifetime-field">
        <label for="reset-lifetime">Link lifetime <span class="label-hint">5 minutes to 24 hours</span></label>
        <div class="lifetime-row">
          <input
            id="reset-lifetime"
            v-model="amount"
            inputmode="numeric"
            autocomplete="off"
            :aria-invalid="lifetimeError ? 'true' : undefined"
            :aria-describedby="lifetimeError ? 'reset-lifetime-error' : undefined"
          />
          <select v-model="unit" aria-label="Unit">
            <option value="minutes">minutes</option>
            <option value="hours">hours</option>
          </select>
        </div>
        <p v-if="lifetimeError" id="reset-lifetime-error" class="form-error" role="alert">{{ lifetimeError }}</p>
      </div>
      <p v-if="saveError" class="form-error" role="alert">{{ saveError }}</p>
      <button class="btn-primary" type="submit" :disabled="saving">{{ saving ? 'Saving…' : 'Save' }}</button>
    </form>
  </section>
</template>
