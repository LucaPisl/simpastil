export type IconName =
  | 'overview' | 'key' | 'people' | 'invite' | 'settings'
  | 'signout' | 'menu' | 'close' | 'sun' | 'moon' | 'auto' | 'arrow' | 'back' | 'device' | 'plus'
  | 'copy' | 'check' | 'unplug' | 'download' | 'shield'

export interface NavItem {
  to: string
  label: string
  icon: IconName
}

export const NAV_ITEMS: readonly NavItem[] = [
  { to: '/dashboard', label: 'Overview', icon: 'overview' },
  { to: '/users', label: 'People', icon: 'people' },
  { to: '/keys', label: 'API keys', icon: 'key' },
  { to: '/invites', label: 'Invites', icon: 'invite' },
  { to: '/settings', label: 'Settings', icon: 'settings' },
]

/**
 * Which navigation item owns a route. Nested pages (a person's keys or
 * devices) belong to their parent section; unknown paths own nothing.
 */
export function activeNavIndex(path: string, items: readonly NavItem[] = NAV_ITEMS): number {
  return items.findIndex((item) => path === item.to || path.startsWith(item.to + '/'))
}
