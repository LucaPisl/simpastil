<script setup lang="ts">
import { ref } from 'vue'
import { createResetLink } from '../settings'
import { formatWhen } from '../audit'
import AppIcon from './AppIcon.vue'
import CopyButton from './CopyButton.vue'
import KeyText from './KeyText.vue'
import ModalDialog from './ModalDialog.vue'

/**
 * Creates a password reset link for one person and shows it once. The link
 * lives only in this component's state: closing the dialog unmounts it, and
 * nothing is written to storage or kept in a store.
 */
defineProps<{ userId: string; email: string }>()
const emit = defineEmits<{ close: [] }>()

const creating = ref(false)
const error = ref('')
const issued = ref<{ link: string; expiresAt: string } | null>(null)

async function create(id: string): Promise<void> {
  creating.value = true
  error.value = ''
  const result = await createResetLink(id)
  creating.value = false
  if (result.ok) issued.value = result.value
  else error.value = result.error
}
</script>

<template>
  <ModalDialog
    :key="issued ? 'link' : 'ask'"
    :role="issued ? 'dialog' : 'alertdialog'"
    :persistent="creating || issued !== null"
    labelledby="reset-link-title"
    describedby="reset-link-body"
    @close="emit('close')"
  >
    <template v-if="!issued">
      <h3 id="reset-link-title">Create a reset link?</h3>
      <div id="reset-link-body">
        <p class="hint">
          This makes a link that lets <strong>{{ email }}</strong> choose a new password. Give it to them
          yourself; the server does not send it.
        </p>
        <p class="hint">
          It works once. Any earlier link for this person stops working, and the new one is shown only now.
        </p>
      </div>
      <p v-if="error" class="form-error" role="alert">{{ error }}</p>
      <div class="modal-actions">
        <button class="btn-ghost" data-autofocus type="button" :disabled="creating" @click="emit('close')">Cancel</button>
        <button class="btn-primary" type="button" :disabled="creating" @click="create(userId)">
          {{ creating ? 'Creating…' : 'Create link' }}
        </button>
      </div>
    </template>
    <template v-else>
      <span class="key-born-mark" aria-hidden="true"><AppIcon name="key" :size="22" /></span>
      <h3 id="reset-link-title">Reset link for {{ email }}</h3>
      <div id="reset-link-body">
        <KeyText class="reset-link-url" :value="issued.link" />
        <p class="reset-link-expiry">Expires {{ formatWhen(issued.expiresAt) }}</p>
        <p class="hint">
          It works once and replaces any earlier link for this person. It will not be shown again; if you
          lose it, create a new one.
        </p>
      </div>
      <CopyButton class="btn-primary key-born-copy" :value="issued.link" label="Copy link" />
      <div class="modal-actions">
        <button class="btn-secondary" data-autofocus type="button" @click="emit('close')">Done</button>
      </div>
    </template>
  </ModalDialog>
</template>
