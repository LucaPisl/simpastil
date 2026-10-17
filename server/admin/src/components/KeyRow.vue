<script setup lang="ts">
import { nextTick, ref } from 'vue'
import api from '../api'
import { useToast } from '../useToast'
import ConfirmStrip from './ConfirmStrip.vue'
import CopyButton from './CopyButton.vue'
import KeyText from './KeyText.vue'

export interface KeyRowKey {
  id: string
  label: string
  encryptedKey: string | null
  revokedAt: string | null
}

/**
 * One API key in a list. Revealing decodes the key in place; revoking asks
 * inside the row first, then unplugs it where it stands: the live dot lets
 * go of its halo and a line is drawn through the name.
 */
const props = defineProps<{ k: KeyRowKey; meta: string; confirming: boolean; fresh?: boolean }>()
const emit = defineEmits<{ 'update:confirming': [open: boolean]; revoked: [id: string] }>()

const { show } = useToast()
const revealed = ref('')
const revealing = ref(false)
const revoking = ref(false)
const unplugged = ref(false)
const revokeButton = ref<HTMLButtonElement>()

async function toggleReveal(): Promise<void> {
  if (revealed.value) {
    revealed.value = ''
    return
  }
  revealing.value = true
  try {
    const res = await api.get(`/admin/keys/${props.k.id}/reveal`)
    if (res.ok) {
      const data = await res.json()
      if (data.rawKey) revealed.value = data.rawKey
      else show('Key value not available — rotate to view', 'error')
    } else {
      show('Failed to reveal key', 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  revealing.value = false
}

async function keep(): Promise<void> {
  emit('update:confirming', false)
  await nextTick()
  revokeButton.value?.focus({ preventScroll: true })
}

async function revoke(): Promise<void> {
  revoking.value = true
  try {
    const res = await api.delete(`/admin/keys/${props.k.id}`)
    if (res.ok) {
      revealed.value = ''
      unplugged.value = true
      emit('update:confirming', false)
      emit('revoked', props.k.id)
      show('Key revoked', 'success')
    } else {
      const data = await res.json().catch(() => ({}))
      show(data.error || 'Failed to revoke key', 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  revoking.value = false
}
</script>

<template>
  <div
    class="card-row key-card-row"
    :class="{ 'is-revoked': k.revokedAt, 'is-unplugged': unplugged, 'is-fresh': fresh, 'is-confirming': confirming }"
    :data-key="k.id"
  >
    <span class="status-dot" :class="k.revokedAt ? 'status-revoked' : 'status-active'" aria-hidden="true"></span>
    <div class="card-main">
      <div class="card-label"><span class="label-text">{{ k.label }}</span></div>
      <div class="card-meta">{{ meta }}</div>
      <Transition name="fold">
        <div v-if="revealed" class="fold">
          <div class="fold-clip">
            <div class="key-reveal-row">
              <KeyText :value="revealed" inline />
              <CopyButton class="btn-sm btn-secondary" :value="revealed" />
            </div>
          </div>
        </div>
      </Transition>
    </div>
    <div class="key-actions">
      <button
        v-if="!k.revokedAt && k.encryptedKey"
        class="btn-secondary btn-sm"
        type="button"
        :disabled="revealing"
        :aria-expanded="!!revealed"
        @click="toggleReveal"
      >{{ revealing ? '...' : revealed ? 'Hide' : 'Reveal' }}</button>
      <span v-else-if="!k.revokedAt && !k.encryptedKey" class="hint" style="font-size:11px">Legacy — rotate to view</span>
      <button
        v-if="!k.revokedAt"
        ref="revokeButton"
        class="btn-danger btn-sm"
        type="button"
        :aria-expanded="confirming"
        @click="emit('update:confirming', !confirming)"
      >Revoke</button>
    </div>
    <Transition name="fold">
      <ConfirmStrip
        v-if="confirming && !k.revokedAt"
        class="fold"
        :title="`Revoke “${k.label}”?`"
        body="Any phone using this key disconnects at once. This can't be undone."
        confirm-label="Revoke key"
        busy-label="Revoking…"
        :busy="revoking"
        @cancel="keep"
        @confirm="revoke"
      />
    </Transition>
  </div>
</template>
