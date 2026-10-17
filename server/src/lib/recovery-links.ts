export type RecoveryLinkKind = 'reset-password' | 'invite';

/** Builds browser-only links: validation tokens exist exclusively after '#'. */
export function buildRecoveryLink(
  publicAppUrl: string | undefined,
  kind: RecoveryLinkKind,
  token: string,
): string {
  const origin = new URL(publicAppUrl ?? 'http://localhost:3000').origin;
  const route = kind === 'invite' ? 'invite' : 'reset-password';
  return `${origin}/#/${route}?token=${encodeURIComponent(token)}`;
}
