<script setup lang="ts">
import { ref, onMounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import api from '../api'
import { useToast } from '../useToast'
import { addedIds } from '../keys'
import { useEscape, vFocus } from '../useEscape'
import AppIcon from '../components/AppIcon.vue'
import CopyButton from '../components/CopyButton.vue'
import EmptyState from '../components/EmptyState.vue'
import KeyRow from '../components/KeyRow.vue'
import KeyText from '../components/KeyText.vue'
import PersonHeader from '../components/PersonHeader.vue'

interface Key {
  id: string
  label: string
  encryptedKey: string | null
  revokedAt: string | null
  createdAt: string
}

const { show } = useToast()
const route = useRoute()
const userId = route.params['id'] as string
const keys = ref<Key[]>([])
const loading = ref(true)
const loadError = ref(false)
const showCreate = ref(false)
const newLabel = ref('')
const rawKey = ref('')
const creating = ref(false)
const confirming = ref<string | null>(null)
const fresh = ref<string[]>([])
// A new key's row lights up once its dialog closes, where it can be seen.
let arriving: string[] = []
watch(rawKey, (key) => {
  if (key || !arriving.length) return
  fresh.value = arriving
  arriving = []
})

useEscape(rawKey, () => (rawKey.value = ''))

/** Loads the keys; a quiet reload keeps the list in place instead of the skeleton. */
async function load(quiet = false): Promise<void> {
  if (!quiet) loading.value = true
  loadError.value = false
  try {
    const keysRes = await api.get(`/admin/users/${userId}/keys`)
    if (keysRes.ok) {
      const next: Key[] = (await keysRes.json()).keys
      if (quiet) {
        arriving = addedIds(keys.value, next)
        if (!rawKey.value) [fresh.value, arriving] = [arriving, []]
      }
      keys.value = next
    } else if (!quiet) {
      loadError.value = true
      show('Could not load keys', 'error')
    }
  } catch {
    if (!quiet) {
      loadError.value = true
      show('Could not load keys', 'error')
    }
  }
  loading.value = false
}

async function createKey(): Promise<void> {
  if (!newLabel.value.trim()) return
  creating.value = true
  try {
    const res = await api.post(`/admin/users/${userId}/keys`, { label: newLabel.value.trim() })
    if (res.ok) {
      const d = await res.json()
      rawKey.value = d.rawKey
      showCreate.value = false
      newLabel.value = ''
      show('API key created', 'success')
      await load(true)
    } else {
      const data = await res.json().catch(() => ({}))
      show(data.error || 'Failed to create key', 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  creating.value = false
}

function revoked(id: string): void {
  const key = keys.value.find((k) => k.id === id)
  if (key) key.revokedAt = new Date().toISOString()
  void load(true)
}

function meta(k: Key): string {
  return k.revokedAt
    ? 'Revoked ' + new Date(k.revokedAt).toLocaleDateString()
    : 'Active since ' + new Date(k.createdAt).toLocaleDateString()
}

onMounted(() => load())
</script>

<template>
  <div>
    <PersonHeader :id="userId" tab="keys" />
    <header class="section-header">
      <p class="page-lede">Keys connect this person's phones to the server by hand.</p>
      <button class="btn-primary" type="button" @click="showCreate = true"><AppIcon name="plus" :size="18" />New key</button>
    </header>
    <Transition name="fold">
      <div v-if="showCreate" class="fold">
        <div class="fold-clip">
          <form class="card" @submit.prevent="createKey" @keydown.esc="showCreate = false; newLabel = ''">
            <h3>New API key</h3>
            <div class="form-field">
              <label for="user-new-key-label">Label</label>
              <input id="user-new-key-label" v-model="newLabel" v-focus placeholder="e.g. Main phone" />
            </div>
            <button class="btn-primary" type="submit" :disabled="creating || !newLabel.trim()">
              {{ creating ? 'Creating…' : 'Generate' }}
            </button>
            <button class="btn-link" type="button" style="margin-left:8px" @click="showCreate = false; newLabel = ''">Cancel</button>
          </form>
        </div>
      </div>
    </Transition>
    <div v-if="rawKey" class="modal-overlay" @click.self="rawKey = ''">
      <div class="modal key-born" role="dialog" aria-modal="true" aria-labelledby="raw-key-title">
        <span class="key-born-mark" aria-hidden="true"><AppIcon name="key" :size="22" /></span>
        <h3 id="raw-key-title">New API key</h3>
        <KeyText :value="rawKey" />
        <CopyButton class="btn-primary key-born-copy" :value="rawKey" />
        <p class="hint">You can also reveal this key later from the keys list.</p>
        <button class="btn-link" type="button" @click="rawKey = ''">Done</button>
      </div>
    </div>
    <template v-if="loading">
      <div class="list" aria-hidden="true">
        <div class="skeleton skeleton-row"></div>
        <div class="skeleton skeleton-row"></div>
      </div>
    </template>
    <template v-else-if="loadError">
      <p class="error-state">Could not load keys. <button class="btn-link" @click="load()">Retry</button></p>
    </template>
    <template v-else>
      <div v-if="keys.length" class="list">
        <KeyRow
          v-for="k in keys"
          :key="k.id"
          :k="k"
          :meta="meta(k)"
          :confirming="confirming === k.id"
          :fresh="fresh.includes(k.id)"
          @update:confirming="(open) => (confirming = open ? k.id : null)"
          @revoked="revoked"
        />
      </div>
      <EmptyState v-else-if="!showCreate" title="No keys yet" body="Create a key to connect this person's phone by hand." />
    </template>
  </div>
</template>
