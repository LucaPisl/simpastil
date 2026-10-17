import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const workflow = readFileSync(join(root, '.gitea/workflows/validate.yml'), 'utf8');
const gitEnv = {
  PATH: process.env.PATH,
  GIT_CONFIG_NOSYSTEM: '1',
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_TERMINAL_PROMPT: '0',
};

// Exercise the workflow itself: copying its commands here would let a workflow
// regression pass while only the test's duplicate remained correct.
function checkoutScripts(source) {
  const lines = source.split('\n');
  const scripts = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() !== '- name: Checkout source without a JavaScript action') continue;
    while (++i < lines.length && lines[i].trim() !== 'run: |') {}
    const body = [];
    while (++i < lines.length && (lines[i].startsWith('          ') || !lines[i].trim())) {
      body.push(lines[i].slice(10));
    }
    scripts.push(body.join('\n'));
    i--;
  }
  assert.equal(scripts.length, 2, 'both native validation jobs must be exercised');
  return scripts;
}

function git(cwd, ...args) {
  const result = spawnSync('git', args, { cwd, env: gitEnv, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function fixture(scratch) {
  const seed = join(scratch, 'seed');
  const server = join(scratch, 'server');
  mkdirSync(seed);
  mkdirSync(server);
  git(seed, 'init', '--initial-branch=master');
  git(seed, 'config', 'user.name', 'Checkout fixture');
  git(seed, 'config', 'user.email', 'fixture@example.invalid');
  git(seed, 'config', 'commit.gpgSign', 'false');
  writeFileSync(join(seed, 'event.txt'), 'event revision\n');
  git(seed, 'add', 'event.txt');
  git(seed, 'commit', '-m', 'Event revision');
  const event = git(seed, 'rev-parse', 'HEAD');
  git(seed, 'tag', 'review-tag');
  writeFileSync(join(seed, 'event.txt'), 'newer branch tip\n');
  git(seed, 'commit', '-am', 'Newer tip');
  const tip = git(seed, 'rev-parse', 'HEAD');
  git(seed, 'branch', 'topic');
  git(seed, 'clone', '--bare', seed, join(server, 'fixture.git'));
  git(join(server, 'fixture.git'), 'update-ref', 'refs/pull/7/merge', event);
  return { server, event, tip };
}

const cases = [
  { name: 'master at event tip', ref: 'refs/heads/master', atTip: true, refAtTip: true },
  { name: 'master advanced after event', ref: 'refs/heads/master', refAtTip: true },
  { name: 'topic advanced after event', ref: 'refs/heads/topic', refAtTip: true },
  { name: 'detached pull-request event', ref: 'refs/pull/7/merge' },
  { name: 'tag event', ref: 'refs/tags/review-tag', refAtTip: false },
];

for (const [index, script] of checkoutScripts(workflow).entries()) {
  test('native validation checkout ' + (index + 1), async (t) => {
    for (const scenario of cases) {
      await t.test(scenario.name, () => {
        const scratch = mkdtempSync(join(tmpdir(), 'simpastil-checkout-test-'));
        try {
          const repo = fixture(scratch);
          const workspace = join(scratch, 'workspace');
          mkdirSync(workspace);
          const expectedSha = scenario.atTip ? repo.tip : repo.event;
          const result = spawnSync('sh', ['-c', script], {
            cwd: workspace,
            encoding: 'utf8',
            env: {
              ...gitEnv,
              CHECKOUT_TOKEN: 'disposable-fixture-token',
              GITHUB_SERVER_URL: 'file://' + resolve(repo.server),
              GITHUB_REPOSITORY: 'fixture',
              GITHUB_SHA: expectedSha,
              GITHUB_REF: scenario.ref,
              GITHUB_WORKSPACE: workspace,
            },
          });
          assert.equal(result.status, 0, result.stderr);
          assert.equal(git(workspace, 'rev-parse', 'HEAD'), expectedSha);
          const symbolicHead = spawnSync('git', ['symbolic-ref', '-q', 'HEAD'], {
            cwd: workspace, env: gitEnv, encoding: 'utf8',
          });
          assert.equal(symbolicHead.status, 1, 'event checkout must stay detached');
          assert.equal(readFileSync(join(workspace, 'event.txt'), 'utf8'),
            scenario.atTip ? 'newer branch tip\n' : 'event revision\n');
          if (scenario.refAtTip !== undefined) {
            assert.equal(git(workspace, 'rev-parse', scenario.ref),
              scenario.refAtTip ? repo.tip : repo.event);
          }
        } finally {
          rmSync(scratch, { recursive: true, force: true });
        }
      });
    }
    await t.test('missing Actions token stops before creating a checkout', () => {
      const workspace = mkdtempSync(join(tmpdir(), 'simpastil-checkout-token-test-'));
      try {
        const result = spawnSync('sh', ['-c', script], {
          cwd: workspace,
          env: { ...gitEnv, GITHUB_WORKSPACE: workspace },
          encoding: 'utf8',
        });
        assert.notEqual(result.status, 0);
        assert.match(result.stderr, /Missing read-only Actions token/);
        assert.equal(existsSync(join(workspace, '.git')), false);
      } finally {
        rmSync(workspace, { recursive: true, force: true });
      }
    });
  });
}
