<script setup lang="ts">
import { ref, onMounted } from 'vue'
import api from '../api'
import { pinRowHeight } from '../keys'
import { useToast } from '../useToast'
import { initial, relativeDay } from '../dashboard'
import AppIcon from '../components/AppIcon.vue'
import EmptyState from '../components/EmptyState.vue'
import { lastRoster, morphName, rememberPeople, type Person } from '../people'

type User = Person

const { show } = useToast()
const seen = lastRoster()
const users = ref<User[]>(seen ?? [])
const loading = ref(seen === null)
const loadError = ref(false)
const deleting = ref<Record<string, boolean>>({})
const confirmDeleteUser = ref<User | null>(null)

/** A quiet reload keeps the list on screen (no skeleton) so rows can fold. */
async function load(quiet = false): Promise<void> {
  loading.value = !quiet
  loadError.value = false
  try {
    const res = await api.get('/admin/users')
    if (res.ok) {
      users.value = (await res.json()).users
      rememberPeople(users.value, { whole: true })
    } else {
      loadError.value = true
      show('Could not load users', 'error')
    }
  } catch {
    loadError.value = true
    show('Could not load users', 'error')
  }
  loading.value = false
}

async function doDelete(): Promise<void> {
  const user = confirmDeleteUser.value
  if (!user) return
  confirmDeleteUser.value = null
  deleting.value[user.id] = true
  try {
    const res = await api.delete(`/admin/users/${user.id}`)
    if (res.ok) {
      show('User deleted', 'success')
      // The row folds away at once; the reload then confirms the list.
      users.value = users.value.filter((u) => u.id !== user.id)
      await load(true)
    } else {
      const data = await res.json().catch(() => ({}))
      show(data.error || 'Failed to delete user', 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  deleting.value[user.id] = false
}

onMounted(() => load(seen !== null))
</script>

<template>
  <div>
    <header class="page-header">
      <div>
        <h1 class="page-title">People</h1>
        <p class="page-lede">Everyone with an account on this server, their keys and their signed-in devices.</p>
      </div>
      <RouterLink to="/invites" class="btn-primary"><AppIcon name="plus" :size="18" />Invite</RouterLink>
    </header>
    <!-- Confirm delete dialog -->
    <div v-if="confirmDeleteUser" class="confirm-overlay" @click.self="confirmDeleteUser = null">
      <div class="confirm-dialog" role="alertdialog" aria-modal="true" aria-labelledby="confirm-delete-title">
        <h3 id="confirm-delete-title">Delete this person?</h3>
        <p>This will permanently delete <strong>{{ confirmDeleteUser.email }}</strong> and all their data.</p>
        <div class="confirm-actions">
          <button class="btn-secondary" @click="confirmDeleteUser = null">Cancel</button>
          <button class="btn-danger" @click="doDelete">Delete</button>
        </div>
      </div>
    </div>
    <template v-if="loading">
      <div class="list" aria-hidden="true">
        <div class="skeleton skeleton-row"></div>
        <div class="skeleton skeleton-row"></div>
        <div class="skeleton skeleton-row"></div>
      </div>
    </template>
    <template v-else-if="loadError">
      <p class="error-state">Could not load users. <button class="btn-link" @click="load()">Retry</button></p>
    </template>
    <template v-else>
      <TransitionGroup v-if="users.length" tag="div" name="row" class="list" @before-leave="pinRowHeight">
      <div v-for="u in users" :key="u.id" class="card-row">
        <RouterLink class="person-link" :to="'/users/' + u.id + '/keys'">
          <span class="avatar" aria-hidden="true" :style="{ viewTransitionName: morphName('avatar', u.id) }">{{ initial(u.email) }}</span>
          <div class="card-main">
            <div class="card-label"><span :style="{ viewTransitionName: morphName('name', u.id) }">{{ u.email }}</span></div>
            <div class="card-meta">Joined {{ relativeDay(u.createdAt) }}</div>
          </div>
        </RouterLink>
        <RouterLink class="btn-secondary btn-sm" :to="'/users/' + u.id + '/keys'">Keys</RouterLink>
        <RouterLink class="btn-secondary btn-sm" :to="'/users/' + u.id + '/devices'">Devices</RouterLink>
        <button
          class="btn-danger btn-sm"
          :disabled="deleting[u.id]"
          @click="confirmDeleteUser = u"
        >{{ deleting[u.id] ? 'Deleting…' : 'Delete' }}</button>
      </div>
      </TransitionGroup>
      <EmptyState v-else title="No people yet" body="Invite someone and their account will appear here.">
        <RouterLink to="/invites" class="btn-secondary btn-sm">Send an invite</RouterLink>
      </EmptyState>
    </template>
  </div>
</template>
