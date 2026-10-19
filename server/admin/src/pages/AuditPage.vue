<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import api from '../api'
import EmptyState from '../components/EmptyState.vue'
import {
  PAGE_SIZE, FILTER_ACTIONS, actionLabel, actionTone, auditQuery, entryDetails, formatWhen,
  type AuditEntry, type AuditPage,
} from '../audit'

const entries = ref<AuditEntry[]>([])
const hasMore = ref(false)
const page = ref(0)
const loading = ref(true)
const loadError = ref(false)
const filters = ref({ action: '', from: '', to: '' })
let request = 0

const rangeBackwards = computed(() => !!filters.value.from && !!filters.value.to && filters.value.from > filters.value.to)
const filtered = computed(() => !!(filters.value.action || filters.value.from || filters.value.to))
const firstShown = computed(() => page.value * PAGE_SIZE + 1)

async function load(): Promise<void> {
  if (rangeBackwards.value) {
    entries.value = []
    hasMore.value = false
    loading.value = false
    loadError.value = false
    return
  }
  const mine = ++request
  loading.value = true
  loadError.value = false
  try {
    const res = await api.get(`/admin/audit-logs?${auditQuery(filters.value, page.value)}`)
    if (mine !== request) return
    if (!res.ok) throw new Error('failed')
    const data = (await res.json()) as AuditPage
    entries.value = data.logs
    hasMore.value = data.hasMore
  } catch {
    if (mine !== request) return
    loadError.value = true
  }
  loading.value = false
}

function applyFilters(): void {
  page.value = 0
  void load()
}

function clearFilters(): void {
  filters.value = { action: '', from: '', to: '' }
}

function go(delta: number): void {
  page.value = Math.max(0, page.value + delta)
  void load()
}

// Choosing a filter applies it at once; there is no separate Apply button.
watch(filters, applyFilters, { deep: true })
onMounted(load)
</script>

<template>
  <div>
    <header class="page-header">
      <div>
        <h1 class="page-title">Audit log</h1>
        <p class="page-lede">What was done in this console and when, newest first. Passwords, keys and codes are never recorded.</p>
      </div>
    </header>

    <form class="card audit-filters" role="search" aria-label="Filter the audit log" @submit.prevent>
      <div class="form-field">
        <label for="audit-action">Action</label>
        <select id="audit-action" v-model="filters.action">
          <option value="">All actions</option>
          <option v-for="a in FILTER_ACTIONS" :key="a.value" :value="a.value">{{ a.label }}</option>
        </select>
      </div>
      <div class="form-field">
        <label for="audit-from">From</label>
        <input id="audit-from" v-model="filters.from" type="date" />
      </div>
      <div class="form-field">
        <label for="audit-to">Until</label>
        <input id="audit-to" v-model="filters.to" type="date" />
      </div>
      <button v-if="filtered" class="btn-ghost audit-clear" type="button" @click="clearFilters">Clear filters</button>
      <p v-if="rangeBackwards" class="form-error audit-range-error" role="alert">The start date is after the end date.</p>
    </form>

    <div v-if="loading" class="list" aria-hidden="true">
      <div class="skeleton skeleton-row"></div>
      <div class="skeleton skeleton-row"></div>
      <div class="skeleton skeleton-row"></div>
    </div>
    <p v-else-if="loadError" class="error-state" role="alert">
      Could not load the audit log. <button class="btn-link" type="button" @click="load()">Retry</button>
    </p>
    <template v-else-if="entries.length">
      <ul class="list audit-list" aria-label="Audit entries">
        <li v-for="e in entries" :key="e.id" class="card-row audit-row">
          <span class="audit-dot" :class="'audit-' + actionTone(e.action)" aria-hidden="true"></span>
          <div class="card-main">
            <div class="card-label audit-label">{{ actionLabel(e) }}</div>
            <div v-if="entryDetails(e).length" class="card-meta audit-details">{{ entryDetails(e).join(' · ') }}</div>
          </div>
          <div class="audit-when">
            <time :datetime="e.createdAt">{{ formatWhen(e.createdAt) }}</time>
            <span v-if="e.ipAddress" class="audit-ip">{{ e.ipAddress }}</span>
          </div>
        </li>
      </ul>
      <nav class="audit-pager" aria-label="Pages">
        <button class="btn-secondary btn-sm" type="button" :disabled="page === 0" @click="go(-1)">Newer</button>
        <span class="audit-pager-info" aria-live="polite">
          Entries {{ firstShown }}–{{ firstShown + entries.length - 1 }}
        </span>
        <button class="btn-secondary btn-sm" type="button" :disabled="!hasMore" @click="go(1)">Older</button>
      </nav>
    </template>
    <EmptyState
      v-else
      :title="filtered ? 'Nothing matches those filters' : 'Nothing recorded yet'"
      :body="filtered ? 'Widen the dates or pick another action.' : 'Actions taken in this console will appear here.'"
    >
      <button v-if="filtered" class="btn-secondary btn-sm" type="button" @click="clearFilters">Clear filters</button>
    </EmptyState>
  </div>
</template>
