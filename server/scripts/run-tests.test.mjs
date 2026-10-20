import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

test('passes container endpoint overrides without forwarding secrets or disabling cleanup', () => {
  const root = mkdtempSync(join(tmpdir(), 'simpastil-test-launcher-'));
  try {
    mkdirSync(join(root, 'scripts'));
    mkdirSync(join(root, 'node_modules/.bin'), { recursive: true });
    copyFileSync(new URL('./run-tests.mjs', import.meta.url), join(root, 'scripts/run-tests.mjs'));
    // Capture the environment at the real subprocess boundary, without starting a database.
    const probe = join(root, 'node_modules/.bin/vitest');
    writeFileSync(probe, '#!/usr/bin/env node\nconsole.log(JSON.stringify(process.env));\n');
    chmodSync(probe, 0o755);
    const result = spawnSync(process.execPath, [join(root, 'scripts/run-tests.mjs')], {
      encoding: 'utf8',
      env: {
        PATH: process.env.PATH,
        DOCKER_HOST: 'unix:///var/run/docker.sock',
        TESTCONTAINERS_HOST_OVERRIDE: 'ci-daemon.example.test',
        TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE: '/run/ci/docker.sock',
        CI: 'true',
        DATABASE_URL: 'production-canary',
        SMTP_PASS: 'production-canary',
        TESTCONTAINERS_RYUK_DISABLED: 'true',
        TESTCONTAINERS_RYUK_PRIVILEGED: 'true',
      },
    });
    assert.equal(result.status, 0, result.stderr);
    const env = JSON.parse(result.stdout);
    assert.equal(env.DOCKER_HOST, 'unix:///var/run/docker.sock');
    assert.equal(env.TESTCONTAINERS_HOST_OVERRIDE, 'ci-daemon.example.test');
    assert.equal(env.TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE, '/run/ci/docker.sock');
    assert.equal(env.CI, 'true');
    for (const key of ['DATABASE_URL', 'SMTP_PASS', 'TESTCONTAINERS_RYUK_DISABLED', 'TESTCONTAINERS_RYUK_PRIVILEGED']) {
      assert.equal(env[key], undefined, `${key} must not cross the test boundary`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
