<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import api from '../api'
import { useToast } from '../useToast'
import { loadSettings, type ResetSettings } from '../settings'

interface SentInvite {
  email: string
  label: string
  at: Date
}

const { show } = useToast()
const email = ref('')
const label = ref('')
const loading = ref(false)
/** The invite just sent: the form gives way to it until "Invite someone else". */
const sent = ref<SentInvite | null>(null)
/** Invites sent during this visit only; nothing here is read back from the server. */
const log = ref<SentInvite[]>([])
/** Null until the settings arrive, or when they cannot be read: the form then stays usable. */
const settings = ref<ResetSettings | null>(null)
const manual = computed(() => settings.value?.effectivePasswordResetMode === 'manual')
const emailInput = ref<HTMLInputElement>()
const again = ref<HTMLButtonElement>()

onMounted(async () => {
  settings.value = await loadSettings()
})

const time = (at: Date) => at.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })

async function send(): Promise<void> {
  loading.value = true
  try {
    const keyLabel = label.value || `Invite for ${email.value}`
    const response = await api.post('/admin/invites', {
      email: email.value,
      label: keyLabel,
    })
    if (response.ok) {
      const invite = { email: email.value, label: keyLabel, at: new Date() }
      sent.value = invite
      log.value = [invite, ...log.value].slice(0, 6)
      email.value = ''
      label.value = ''
    } else {
      const data = await response.json().catch(() => ({}))
      show(data.error || 'Could not queue invitation', 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  loading.value = false
}

function another(): void {
  sent.value = null
}

/** The swap is out-in, so whichever side arrives exists only once it has entered. */
function entered(): void {
  if (sent.value) again.value?.focus({ preventScroll: true })
  else emailInput.value?.focus()
}
</script>

<template>
  <div>
    <header class="page-header">
      <div>
        <h1 class="page-title">Invites</h1>
        <p class="page-lede">Send a one-time setup link. The recipient's key is revealed to them once, when they accept.</p>
      </div>
    </header>
    <section v-if="manual" class="card card-form invite-off" aria-labelledby="invite-off-title">
      <h3 id="invite-off-title">Email invitations are off</h3>
      <p class="hint">
        Password reset is set to manual, so this server does not send email links. Create an API key for the
        person instead, or switch password reset back to email in the settings once the server can send email.
      </p>
      <div class="invite-off-actions">
        <RouterLink to="/keys" class="btn-primary">Create an API key</RouterLink>
        <RouterLink to="/settings" class="btn-secondary">Open settings</RouterLink>
      </div>
    </section>
    <div v-else class="card card-form invite-card">
      <Transition name="invite-swap" mode="out-in" @after-enter="entered">
        <form v-if="!sent" key="form" @submit.prevent="send">
          <div class="form-field">
            <label for="invite-email">Recipient email</label>
            <input id="invite-email" ref="emailInput" v-model="email" type="email" autocomplete="off" required />
          </div>
          <div class="form-field">
            <label for="invite-label">Key label</label>
            <input id="invite-label" v-model="label" placeholder="e.g. Alice's phone" required />
          </div>
          <button class="btn-primary" type="submit" :disabled="loading">
            {{ loading ? 'Sending…' : 'Send invite' }}
          </button>
        </form>
        <div v-else key="sent" class="invite-sent" role="status">
          <svg class="invite-flight" viewBox="0 0 240 72" aria-hidden="true">
            <path class="invite-trail" d="M44 44 C 100 44, 150 20, 206 30" />
            <g class="invite-envelope">
              <rect class="invite-envelope-body" x="8" y="28" width="44" height="30" rx="5" />
              <path class="invite-envelope-fold" d="M10 56 L30 41 L50 56" />
              <path class="invite-envelope-flap" d="M9 30 L30 46 L51 30 Z" />
            </g>
            <g class="invite-arrived">
              <circle cx="210" cy="30" r="13" />
              <path d="M204 30.5 l4.2 4.2 l8 -8.4" />
            </g>
          </svg>
          <p class="invite-sent-title">Invitation queued for {{ sent.email }}</p>
          <p class="invite-sent-body">
            The server sends them a one-time setup link for “{{ sent.label }}”. Their key is shown to them once, when they accept.
          </p>
          <button ref="again" class="btn-secondary" type="button" @click="another">Invite someone else</button>
        </div>
      </Transition>
    </div>

    <section v-if="log.length" class="invite-log" aria-labelledby="invite-log-title">
      <h2 id="invite-log-title" class="invite-log-title">Sent from this page</h2>
      <TransitionGroup tag="ul" name="invite-row" class="invite-log-list">
        <li v-for="item in log" :key="item.at.getTime() + item.email" class="invite-log-row">
          <span class="invite-log-dot" aria-hidden="true"></span>
          <span class="invite-log-email">{{ item.email }}</span>
          <span class="invite-log-label">{{ item.label }}</span>
          <time class="invite-log-time" :datetime="item.at.toISOString()">{{ time(item.at) }}</time>
        </li>
      </TransitionGroup>
      <p class="invite-log-note">Only for this visit. Reloading the page clears this list; the invitations stay queued.</p>
    </section>
  </div>
</template>
