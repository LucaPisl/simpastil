import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const serverRoot = resolve(scriptDir, '..');

// Only disposable test coordinates and harness metadata cross into Vitest.
// In particular, production DATABASE_URL/JWT/TOTP/SMTP/admin values are not
// forwarded, even when a developer launches npm test from a live shell.
const testInputNames = [
  'TEST_DATABASE_URL',
  'TEST_DATABASE_URL_SUPER',
  'TEST_DATABASE_URL_APP',
  'TEST_DATABASE_URL_OUTBOX',
  'SIMPASTIL_BOOTSTRAP_MARKER',
  'TEST_POSTGRES_IMAGE',
  'DOCKER_HOST',
  // Job-visible API socket, daemon-side Ryuk bind source, and published-port
  // host can differ under rootless DinD. Keep these explicit; never forward
  // all TESTCONTAINERS_* values (including cleanup/privilege bypasses).
  'TESTCONTAINERS_HOST_OVERRIDE',
  'TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE',
  'DEBUG',
];
const env = {
  PATH: process.env['PATH'] ?? '',
  NODE_ENV: 'test',
};
for (const name of testInputNames) {
  const value = process.env[name];
  if (value !== undefined) env[name] = value;
}

// Preserve the repository's legacy test names only as values explicitly
// copied from TEST_* inputs, never from a parent process's live variables.
const appUrl = env['TEST_DATABASE_URL_APP'] ?? env['TEST_DATABASE_URL'];
const superUrl = env['TEST_DATABASE_URL_SUPER'];
if (appUrl) {
  env['DATABASE_URL'] = appUrl;
  env['DATABASE_URL_APP'] = appUrl;
}
if (superUrl) env['DATABASE_URL_SUPER'] = superUrl;
if (env['TEST_DATABASE_URL_OUTBOX']) env['DATABASE_URL_OUTBOX'] = env['TEST_DATABASE_URL_OUTBOX'];

const cliArgs = process.argv.slice(2);
const vitestArgs = cliArgs.includes('--watch') || cliArgs.includes('--ui')
  ? cliArgs
  : ['run', ...cliArgs];
const vitest = resolve(serverRoot, 'node_modules/.bin/vitest');

const child = spawn(vitest, vitestArgs, {
  cwd: serverRoot,
  env,
  stdio: 'inherit',
});

child.on('error', (error) => {
  console.error(`Unable to start Vitest: ${error.message}`);
  process.exitCode = 1;
});
child.on('exit', (code, signal) => {
  process.exitCode = signal ? 1 : (code ?? 1);
});
