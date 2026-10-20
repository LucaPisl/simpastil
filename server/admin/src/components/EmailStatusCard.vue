<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { formatWhen } from '../audit'
import { EMAIL_FAILURE_WINDOW_DAYS, loadEmailStatus, settingsSaves, type EmailStatus } from '../settings'

const status = ref<EmailStatus | null>(null)
const loadError = ref(false)
const refreshing = ref(false)

async function load(): Promise<void> {
  refreshing.value = true
  loadError.value = false
  const result = await loadEmailStatus()
  if (result) status.value = result
  else loadError.value = true
  refreshing.value = false
}

onMounted(load)
// The reset mode shown here comes from the settings card above, so follow its saves.
watch(settingsSaves, load)
</script>

<template>
  <section class="card card-form" aria-labelledby="email-status-heading">
    <h3 id="email-status-heading">Email</h3>
    <div v-if="loadError" class="error-state">
      Could not load the email status. <button class="btn-link" type="button" @click="load()">Retry</button>
    </div>
    <div v-else-if="!status" class="skeleton email-skeleton" aria-hidden="true"></div>
    <template v-else>
      <dl class="email-facts">
        <div>
          <dt>Sending</dt>
          <dd v-if="status.configured"><span class="status-dot status-active" aria-hidden="true"></span>Configured</dd>
          <dd v-else><span class="status-dot status-revoked" aria-hidden="true"></span>Not configured</dd>
        </div>
        <div>
          <dt>Password reset</dt>
          <dd>{{ status.effectiveMode === 'email' ? 'By email' : 'Links handed over by you' }}</dd>
        </div>
        <div>
          <dt>Last {{ EMAIL_FAILURE_WINDOW_DAYS }} days</dt>
          <dd v-if="status.recentPermanentFailures === 0">
            <span class="status-dot status-active" aria-hidden="true"></span>No failed deliveries
          </dd>
          <dd v-else class="email-failed">
            <span class="status-dot status-failed" aria-hidden="true"></span>
            {{ status.recentPermanentFailures }} {{ status.recentPermanentFailures === 1 ? 'email' : 'emails' }}
            could not be delivered
            <small v-if="status.lastPermanentFailureAt">Last failure {{ formatWhen(status.lastPermanentFailureAt) }}</small>
          </dd>
        </div>
      </dl>
      <p v-if="!status.configured" class="hint">
        This server has no mail settings, so it sends nothing. To send reset and invitation emails, set
        <code>SMTP_HOST</code> as described in DEPLOYMENT.md.
      </p>
      <p v-else-if="status.recentPermanentFailures > 0" class="hint">
        A permanent failure means the mail server refused the message, for example a wrong address or
        rejected sign-in. Check the SMTP settings in DEPLOYMENT.md (Configuration and secret files).
      </p>
      <button class="btn-secondary" type="button" :disabled="refreshing" @click="load()">
        {{ refreshing ? 'Checking…' : 'Check again' }}
      </button>
    </template>
  </section>
</template>
