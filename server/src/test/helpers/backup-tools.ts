import { spawnSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';

// OpenSSL 3.0 has no --version flag; it answers `openssl version`.
const versionArgs = (tool: string) => (tool === 'openssl' ? ['version'] : ['--version']);
const hasTool = (tool: string) => spawnSync(tool, versionArgs(tool), { stdio: 'ignore' }).status === 0;
const requiredTools = ['pg_dump', 'psql', 'openssl', 'bash'] as const;
const missingTools = requiredTools.filter((tool) => !hasTool(tool));

/**
 * Backup bundle suites shell out to the PostgreSQL client tools. Locally they
 * are skipped when a tool is missing; under CI (`CI=true`) a missing tool is a
 * failure, so a runner without the client can never turn these suites into a
 * silent green no-op.
 */
export function describeBackupTools(name: string, body: () => void): void {
  if (missingTools.length === 0) {
    describe(name, body);
  } else if (process.env['CI'] === 'true') {
    describe(name, () => {
      it('has the backup tools installed', () => {
        expect(missingTools, 'CI runners must provide these tools').toEqual([]);
      });
    });
  } else {
    describe.skip(name, body);
  }
}
