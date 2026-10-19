<script setup lang="ts">
import { computed, ref, onMounted } from 'vue'
import api from '../api'
import { useInvitesOff } from '../settings'
import { useToast } from '../useToast'
import { greeting } from '../sky'
import {
  initial, relativeDay, serverInfo, serverUpdateBanner, summarize,
  type DashKey, type DashUser, type Overview, type ServerInfo,
} from '../dashboard'
import SkyScene from '../components/SkyScene.vue'
import AppIcon from '../components/AppIcon.vue'
import EmptyState from '../components/EmptyState.vue'

const { show } = useToast()
const overview = ref<Overview | null>(null)
const loading = ref(true)
const loadError = ref(false)
const updateBanner = ref<{ version: string; url: string } | null>(null)
const server = ref<ServerInfo | null>(null)
/** Email invitations only work while password reset is not manual. */
const invitesOff = useInvitesOff()
const now = new Date()
const hello = greeting(now)
const today = now.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' })

async function load(): Promise<void> {
  loading.value = true
  loadError.value = false
  try {
    const [usersRes, keysRes] = await Promise.all([
      api.get('/admin/users'),
      api.get('/admin/keys'),
    ])
    if (usersRes.ok && keysRes.ok) {
      const { users } = await usersRes.json() as { users: DashUser[] }
      const { keys } = await keysRes.json() as { keys: DashKey[] }
      overview.value = summarize(users, keys)
    } else {
      loadError.value = true
      show('Could not load dashboard data', 'error')
    }
  } catch {
    loadError.value = true
    show('Could not load dashboard data', 'error')
  }
  loading.value = false
}

const gauge = computed(() => `${Math.round((overview.value?.activeShare ?? 0) * 100)}%`)

async function loadUpdateBanner(): Promise<void> {
  try {
    const res = await fetch('/api/v1/capabilities')
    if (res.ok) {
      const caps: unknown = await res.json()
      updateBanner.value = serverUpdateBanner(caps)
      server.value = serverInfo(caps)
    }
  } catch {
    updateBanner.value = null
    server.value = null
  }
}

onMounted(() => {
  void load()
  void loadUpdateBanner()
})
</script>

<template>
  <div class="dashboard">
    <SkyScene class="hero" :horizon="0.86" :arc="0.24">
      <div class="hero-copy">
        <p class="hero-date">{{ today }}</p>
        <h1 class="hero-title">{{ hello }}</h1>
        <p class="hero-summary" aria-live="polite">
          <template v-if="loading">Gathering the latest from this server…</template>
          <template v-else-if="loadError">The server did not answer just now.</template>
          <template v-else>{{ overview?.summary }}</template>
        </p>
      </div>
    </SkyScene>

    <div v-if="updateBanner" class="panel notice" role="status">
      <div>
        <p class="notice-title">Server update available: {{ updateBanner.version }}</p>
        <p class="notice-body">A newer Simpastil release is published.</p>
      </div>
      <a class="btn-secondary" :href="updateBanner.url" target="_blank" rel="noopener noreferrer">Release notes</a>
    </div>

    <template v-if="loading">
      <div class="stat-grid" aria-hidden="true">
        <div class="stat-tile skeleton"></div>
        <div class="stat-tile skeleton"></div>
        <div class="stat-tile skeleton"></div>
      </div>
      <div class="panel-grid" aria-hidden="true">
        <div class="panel skeleton skeleton-panel"></div>
        <div class="panel skeleton skeleton-panel"></div>
      </div>
    </template>

    <div v-else-if="loadError" class="panel notice" role="alert">
      <div>
        <p class="notice-title">Could not load dashboard data.</p>
        <p class="notice-body">Check that the API is running, then try again.</p>
      </div>
      <button class="btn-secondary" type="button" @click="load">Retry</button>
    </div>

    <template v-else-if="overview">
      <section class="stat-grid" aria-label="At a glance">
        <RouterLink to="/users" class="stat-tile stat-link" :style="{ '--i': 0 }">
          <span class="stat-icon"><AppIcon name="people" /></span>
          <span class="stat-num">{{ overview.users }}</span>
          <span class="stat-label">{{ overview.users === 1 ? 'Person' : 'People' }}</span>
        </RouterLink>
        <RouterLink to="/keys" class="stat-tile stat-link" :style="{ '--i': 1 }">
          <span class="stat-icon"><AppIcon name="key" /></span>
          <span class="stat-num">{{ overview.activeKeys }}</span>
          <span class="stat-label">Active keys</span>
          <span
            class="capsule-gauge"
            role="img"
            :aria-label="`${overview.activeKeys} of ${overview.activeKeys + overview.revokedKeys} keys active`"
          >
            <span class="capsule-fill" :style="{ width: gauge }"></span>
          </span>
        </RouterLink>
        <div class="stat-tile stat-quiet" :style="{ '--i': 2 }">
          <span class="stat-icon"><AppIcon name="key" /></span>
          <span class="stat-num">{{ overview.revokedKeys }}</span>
          <span class="stat-label">Revoked keys</span>
        </div>
      </section>

      <div class="panel-grid">
        <section class="panel" aria-labelledby="recent-people">
          <header class="panel-head">
            <h2 id="recent-people" class="panel-title">Recently joined</h2>
            <RouterLink to="/users" class="panel-link">All people <AppIcon name="arrow" :size="16" /></RouterLink>
          </header>
          <ul v-if="overview.recentUsers.length" class="mini-list">
            <li v-for="u in overview.recentUsers" :key="u.id" class="mini-row">
              <span class="avatar" aria-hidden="true">{{ initial(u.email) }}</span>
              <span class="mini-main">
                <span class="mini-label">{{ u.email }}</span>
                <span class="mini-meta">Joined {{ relativeDay(u.createdAt) }}</span>
              </span>
            </li>
          </ul>
          <EmptyState v-else title="No one has joined yet" body="Send an invitation and it will show up here.">
            <RouterLink v-if="!invitesOff" to="/invites" class="btn-secondary btn-sm">Invite someone</RouterLink>
          </EmptyState>
        </section>

        <section class="panel" aria-labelledby="recent-keys">
          <header class="panel-head">
            <h2 id="recent-keys" class="panel-title">Keys in use</h2>
            <RouterLink to="/keys" class="panel-link">All keys <AppIcon name="arrow" :size="16" /></RouterLink>
          </header>
          <ul v-if="overview.recentKeys.length" class="mini-list">
            <li v-for="k in overview.recentKeys" :key="k.id" class="mini-row">
              <span class="status-dot status-active" aria-hidden="true"></span>
              <span class="mini-main">
                <span class="mini-label">{{ k.label }}</span>
                <span class="mini-meta">Last used {{ relativeDay(k.lastUsedAt) }}</span>
              </span>
            </li>
          </ul>
          <EmptyState v-else title="No active keys" body="Create a key to connect a phone to this server.">
            <RouterLink to="/keys" class="btn-secondary btn-sm">New key</RouterLink>
          </EmptyState>
        </section>
      </div>

      <section v-if="server" class="panel server-card" aria-labelledby="server-card-title">
        <header class="panel-head">
          <h2 id="server-card-title" class="panel-title">This server</h2>
        </header>
        <dl class="server-facts">
          <div>
            <dt>Version</dt>
            <dd>{{ server.version }}</dd>
          </div>
          <div v-if="server.release">
            <dt>Database schema</dt>
            <dd>{{ server.release }}</dd>
          </div>
          <div>
            <dt>Updates</dt>
            <dd v-if="server.update.state === 'available'" class="server-update">
              <span class="status-dot server-dot-available" aria-hidden="true"></span>{{ server.update.latest }} is available
            </dd>
            <dd v-else-if="server.update.state === 'current'">
              <span class="status-dot status-active" aria-hidden="true"></span>Up to date
            </dd>
            <dd v-else class="server-unknown">
              No answer yet
              <small>The check runs once a day and may be switched off.</small>
            </dd>
          </div>
        </dl>
      </section>

      <section class="quick-actions" aria-label="Quick actions">
        <div v-if="invitesOff" class="quick-action is-off" role="group" aria-label="Invite someone, unavailable">
          <AppIcon name="invite" />
          <span><strong>Invitations are off</strong><small>Password reset is manual, so no email links</small></span>
        </div>
        <RouterLink v-else to="/invites" class="quick-action">
          <AppIcon name="invite" />
          <span><strong>Invite someone</strong><small>Email a one-time setup link</small></span>
        </RouterLink>
        <RouterLink to="/keys" class="quick-action">
          <AppIcon name="key" />
          <span><strong>Create an API key</strong><small>Connect a phone by hand</small></span>
        </RouterLink>
        <RouterLink to="/settings" class="quick-action">
          <AppIcon name="settings" />
          <span><strong>Settings</strong><small>Theme and admin password</small></span>
        </RouterLink>
      </section>
    </template>
  </div>
</template>
