import { createApp, h, defineComponent } from 'vue'
import { createRouter, createWebHashHistory, RouterView } from 'vue-router'
import './assets/style.css'

import AppShell from './App.vue'
import SetupPage from './pages/SetupPage.vue'
import LoginPage from './pages/LoginPage.vue'
import ResetPasswordPage from './pages/ResetPasswordPage.vue'
import InviteAcceptPage from './pages/InviteAcceptPage.vue'
import DashboardPage from './pages/DashboardPage.vue'
import KeysPage from './pages/KeysPage.vue'
import UsersPage from './pages/UsersPage.vue'
import UserKeysPage from './pages/UserKeysPage.vue'
import UserDevicesPage from './pages/UserDevicesPage.vue'
import InvitesPage from './pages/InvitesPage.vue'
import AuditPage from './pages/AuditPage.vue'
import SettingsPage from './pages/SettingsPage.vue'
import { installPersonMorph } from './people'

const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', redirect: '/dashboard' },
    { path: '/setup', component: SetupPage },
    { path: '/login', component: LoginPage },
    { path: '/reset-password', component: ResetPasswordPage },
    { path: '/invite', component: InviteAcceptPage },
    {
      path: '/',
      component: AppShell,
      children: [
        { path: 'dashboard', component: DashboardPage },
        { path: 'keys', component: KeysPage },
        { path: 'users', component: UsersPage },
        { path: 'users/:id/keys', component: UserKeysPage },
        { path: 'users/:id/devices', component: UserDevicesPage },
        { path: 'invites', component: InvitesPage },
        { path: 'audit', component: AuditPage },
        { path: 'settings', component: SettingsPage },
      ],
    },
  ],
})

router.beforeEach(async (to) => {
  if (to.path === '/setup' || to.path === '/reset-password' || to.path === '/invite') return
  const token = localStorage.getItem('admin_token')
  if (token && to.path !== '/login') {
    try {
      const payload = JSON.parse(atob(token.split('.')[1]))
      if (payload.exp && payload.exp < Date.now() / 1000) {
        localStorage.removeItem('admin_token')
        localStorage.removeItem('admin_refresh_token')
        return '/login'
      }
    } catch {
      localStorage.removeItem('admin_token')
      localStorage.removeItem('admin_refresh_token')
      return '/login'
    }
  }
  if (!token && to.path !== '/login') return '/login'
  if (to.path === '/login') {
    try {
      const res = await fetch('/api/v1/admin/status')
      if (res.ok) {
        const { configured } = await res.json()
        if (!configured) return '/setup'
      }
    } catch { /* ignore network errors */ }
  }
})

installPersonMorph(router)

// Root component uses a render function — no string template, no runtime compilation needed.
const Root = defineComponent({ render: () => h(RouterView) })
const app = createApp(Root)
app.use(router)
app.mount('#app')
