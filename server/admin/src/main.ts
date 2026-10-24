import { createApp, h, defineComponent } from 'vue'
import { createRouter, createWebHashHistory, RouterView } from 'vue-router'
import './assets/style.css'

import AppShell from './App.vue'
import SetupPage from './pages/SetupPage.vue'
import LoginPage from './pages/LoginPage.vue'
import ResetPasswordPage from './pages/ResetPasswordPage.vue'
import ConfirmEmailPage from './pages/ConfirmEmailPage.vue'
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
import { adminGuard } from './guard'

const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', redirect: '/dashboard' },
    { path: '/setup', component: SetupPage },
    { path: '/login', component: LoginPage },
    { path: '/reset-password', component: ResetPasswordPage },
    { path: '/confirm-email', component: ConfirmEmailPage },
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

router.beforeEach(adminGuard)

installPersonMorph(router)

// Root component uses a render function — no string template, no runtime compilation needed.
const Root = defineComponent({ render: () => h(RouterView) })
const app = createApp(Root)
app.use(router)
app.mount('#app')
