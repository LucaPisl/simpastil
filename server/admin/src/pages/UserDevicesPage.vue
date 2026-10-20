<script setup lang="ts">
import { nextTick, ref, onMounted } from 'vue'
import { useRoute } from 'vue-router'
import api from '../api'
import { pinRowHeight } from '../keys'
import { useToast } from '../useToast'
import { relativeDay } from '../dashboard'
import AppIcon from '../components/AppIcon.vue'
import ConfirmStrip from '../components/ConfirmStrip.vue'
import EmptyState from '../components/EmptyState.vue'
import PersonHeader from '../components/PersonHeader.vue'

interface Device {
  family_id: string
  device_name: string | null
  last_used_at: string
}

const { show } = useToast()
const route = useRoute()
const userId = route.params['id'] as string
const devices = ref<Device[]>([])
const loading = ref(true)
const loadError = ref(false)
const loggingOut = ref<Record<string, boolean>>({})
const confirming = ref<string | null>(null)

/** Loads the devices; a quiet reload keeps the list in place instead of the skeleton. */
async function load(quiet = false): Promise<void> {
  if (!quiet) loading.value = true
  loadError.value = false
  try {
    const res = await api.get(`/admin/users/${userId}/devices`)
    if (res.ok) {
      devices.value = (await res.json()).devices
    } else if (!quiet) {
      loadError.value = true
      show('Could not load devices', 'error')
    }
  } catch {
    if (!quiet) {
      loadError.value = true
      show('Could not load devices', 'error')
    }
  }
  loading.value = false
}

async function keep(familyId: string): Promise<void> {
  confirming.value = null
  await nextTick()
  document.querySelector<HTMLButtonElement>(`[data-signout="${familyId}"]`)?.focus({ preventScroll: true })
}

async function logout(familyId: string): Promise<void> {
  loggingOut.value[familyId] = true
  try {
    const res = await api.delete(`/admin/users/${userId}/devices/${familyId}`)
    if (res.ok) {
      // The row folds out where it stood; the list closes the gap.
      confirming.value = null
      devices.value = devices.value.filter((d) => d.family_id !== familyId)
      show('Device signed out', 'success')
      void load(true)
    } else {
      const data = await res.json().catch(() => ({}))
      show(data.error || 'Failed to logout device', 'error')
    }
  } catch {
    show('Network error', 'error')
  }
  loggingOut.value[familyId] = false
}

onMounted(() => load())
</script>

<template>
  <div>
    <PersonHeader :id="userId" tab="devices" />
    <header class="section-header">
      <p class="page-lede">Devices signed in to this account. Signing one out ends its session. A device that synced recently can keep syncing until its current access expires, 15 minutes by default.</p>
    </header>
    <template v-if="loading">
      <div class="list" aria-hidden="true">
        <div class="skeleton skeleton-row"></div>
        <div class="skeleton skeleton-row"></div>
      </div>
    </template>
    <template v-else-if="loadError">
      <p class="error-state">Could not load devices. <button class="btn-link" @click="load()">Retry</button></p>
    </template>
    <template v-else>
      <TransitionGroup v-if="devices.length" tag="div" name="row" class="list" @before-leave="pinRowHeight">
        <div v-for="d in devices" :key="d.family_id" class="card-row" :class="{ 'is-confirming': confirming === d.family_id }">
          <span class="avatar avatar-icon" aria-hidden="true"><AppIcon name="device" :size="18" /></span>
          <div class="card-main">
            <div class="card-label">{{ d.device_name ?? '(unnamed device)' }}</div>
            <div class="card-meta">Last active {{ relativeDay(d.last_used_at) }}</div>
          </div>
          <button
            class="btn-danger btn-sm"
            type="button"
            :data-signout="d.family_id"
            :aria-expanded="confirming === d.family_id"
            @click="confirming = confirming === d.family_id ? null : d.family_id"
          >Sign out</button>
          <Transition name="fold">
            <ConfirmStrip
              v-if="confirming === d.family_id"
              class="fold"
              :title="`Sign out ${d.device_name ?? 'this device'}?`"
              body="It stops syncing until this person signs in on it again."
              confirm-label="Sign out"
              busy-label="Signing out…"
              :busy="loggingOut[d.family_id]"
              @cancel="keep(d.family_id)"
              @confirm="logout(d.family_id)"
            />
          </Transition>
        </div>
      </TransitionGroup>
      <EmptyState v-else title="No signed-in devices" body="When this person signs in on a phone, it will appear here." />
    </template>
  </div>
</template>
