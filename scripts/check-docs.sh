#!/usr/bin/env bash
# Documentation gate. Read-only: it builds nothing and writes nothing.
#
# It checks only material that ships in the public source tree, so it gives
# the same result on a full checkout and on an exported snapshot (see
# scripts/publish/export-public-tree.sh). It does not need git.
#
#   1. The entry documents exist and contain the required commands, headings
#      and operational facts.
#   2. docker-compose.yml does not pin a stale release id.
#   3. Only the supported entry documents sit at the repository root.
#   4. Every relative link in the public Markdown files resolves, and every
#      #fragment names a heading of the target file (GitHub slug rules).
#   5. Required command blocks state their working directory.
#   6. The entry documents contain no key or token examples, no literal email
#      address, no privileged runtime database URL and no developer home path.
#   7. The committed OpenAPI document exists. Drift between it and the routes
#      is checked by `npm run openapi:check` in server/ (the server CI job),
#      not here, because that command compiles the server.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_file() { [[ -f "$root/$1" ]] || fail "required documentation file is missing: $1"; }
require_text() {
  grep -Fq -- "$2" "$root/$1" || fail "$1 is missing required text: $2"
}

entry_files=(
  README.md CONTRIBUTING.md DEPLOYMENT.md SECURITY.md CHANGELOG.md
  docs/ARCHITECTURE.md docs/RELEASE.md docs/INSTALL-ANDROID.md
)
for file in "${entry_files[@]}"; do require_file "$file"; done
require_file server/openapi/openapi.json

require_text README.md 'CONTRIBUTING.md'
require_text README.md 'DEPLOYMENT.md'
require_text README.md 'docs/ARCHITECTURE.md'
require_text README.md 'docs/RELEASE.md'
# Every shipped migration is named in the deployment guide.
for migration in "$root"/server/src/db/migrations/*.sql; do
  name=$(basename "$migration")
  # Migrations before 0018 predate the guide's upgrade notes.
  [[ "$name" < 0018 ]] && continue
  require_text DEPLOYMENT.md "$name"
done
require_text DEPLOYMENT.md 'that an earlier install set'
require_text DEPLOYMENT.md 'confirm `GET /api/v1/health/ready` returns 200'
require_text DEPLOYMENT.md 'GET /api/v1/health/ready'
require_text DEPLOYMENT.md 'Bare `/` returns 404'
require_text DEPLOYMENT.md 'scripts/backup.sh'
require_text DEPLOYMENT.md 'scripts/restore.sh'
require_text CONTRIBUTING.md 'cd server'
require_text CONTRIBUTING.md 'cd flutter_app'
require_text docs/ARCHITECTURE.md 'server/openapi/openapi.json'
require_text docs/ARCHITECTURE.md 'npm run openapi:check'
require_text docs/ARCHITECTURE.md '88 days'
require_text docs/ARCHITECTURE.md '90 days'
require_text docs/RELEASE.md 'targetMinimumClientBuild'
require_text README.md 'docs/INSTALL-ANDROID.md'
require_text docs/README.md 'INSTALL-ANDROID.md'

# A stock install must not pin a stale release id (it made readiness 503).
if grep -E 'RELEASE_ID: *\$\{RELEASE_ID:-[^}]+\}' "$root/docker-compose.yml" >/dev/null; then
  fail 'docker-compose.yml must not default RELEASE_ID to a literal release id'
fi

# Only the supported entry points live at the repository root. Agent
# instruction files (AGENT*.md) are not product documentation and are ignored.
shopt -s nullglob
for path in "$root"/*.md "$root"/*.png "$root"/*.jpg "$root"/*.jpeg "$root"/*.gif "$root"/*.webp "$root"/*.svg; do
  file=${path#"$root"/}
  case "$file" in
    README.md|CONTRIBUTING.md|DEPLOYMENT.md|SECURITY.md|CHANGELOG.md) ;;
    AGENT*.md) ;;
    *) fail "$file belongs under docs/ (root allows only README, CONTRIBUTING, DEPLOYMENT, SECURITY and CHANGELOG)" ;;
  esac
done
shopt -u nullglob

# Link and anchor check over the public Markdown set.
node --input-type=module - "$root" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const root = process.argv[2];
const skipDirs = new Set(['node_modules', '.git', '.dart_tool', 'build', 'dist', '.worktrees', '.gradle']);

// Public documentation: root guides, the three published docs/ locations, and
// the README files that live next to source code.
const isPublicDoc = (rel) =>
  /^(README|CONTRIBUTING|DEPLOYMENT|SECURITY|CHANGELOG)\.md$/.test(rel) ||
  /^docs\/(README|ARCHITECTURE|RELEASE|INSTALL-ANDROID)\.md$/.test(rel) ||
  /^docs\/decisions\/[^/]+\.md$/.test(rel) ||
  /^(flutter_app|server|contracts|nginx|scripts)\/(?:[^/]+\/)*[^/]+\.md$/.test(rel);

const files = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (!skipDirs.has(entry.name)) walk(path.join(dir, entry.name));
    } else if (entry.name.endsWith('.md')) {
      const rel = path.relative(root, path.join(dir, entry.name)).split(path.sep).join('/');
      if (isPublicDoc(rel)) files.push(rel);
    }
  }
})(root);

function stripInline(text) {
  return text
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/<[^>]+>/g, '')
    .replace(/[`*_~]/g, (c) => (c === '_' ? '_' : ''));
}
function slugify(heading) {
  return stripInline(heading)
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .replace(/\s/g, '-');
}
const anchorCache = new Map();
function anchorsOf(abs) {
  if (anchorCache.has(abs)) return anchorCache.get(abs);
  const anchors = new Set();
  const seen = new Map();
  let fence = null;
  for (const line of fs.readFileSync(abs, 'utf8').split('\n')) {
    const f = line.match(/^\s*(```+|~~~+)/);
    if (f) {
      if (!fence) fence = f[1][0];
      else if (f[1][0] === fence) fence = null;
      continue;
    }
    if (fence) continue;
    const h = line.match(/^ {0,3}#{1,6}\s+(.*?)\s*#*\s*$/);
    if (h) {
      const base = slugify(h[1]);
      const n = seen.get(base) ?? 0;
      seen.set(base, n + 1);
      anchors.add(n === 0 ? base : `${base}-${n}`);
    }
    for (const m of line.matchAll(/<a\s+(?:name|id)="([^"]+)"/g)) anchors.add(m[1]);
  }
  anchorCache.set(abs, anchors);
  return anchors;
}

// Drops fenced code blocks line by line. A single multi-line regex pairs the
// wrong fences when blocks are indented (list items) and then hides most of a
// document from the link check.
function stripFences(text) {
  const kept = [];
  let fence = null;
  for (const line of text.split('\n')) {
    const f = line.match(/^\s*(```+|~~~+)/);
    if (f) {
      if (!fence) fence = f[1][0];
      else if (f[1][0] === fence) fence = null;
      continue;
    }
    if (!fence) kept.push(line);
  }
  return kept.join('\n');
}

const failures = [];
for (const rel of files.sort()) {
  const abs = path.join(root, rel);
  let source = fs.readFileSync(abs, 'utf8');
  // Links inside fenced or inline code are examples, not links.
  source = stripFences(source).replace(/`[^`\n]*`/g, '');
  for (const match of source.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
    const raw = match[1].trim().replace(/^<|>$/g, '').split(/\s+/, 1)[0];
    if (!raw || /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(raw)) continue;
    const hashAt = raw.indexOf('#');
    const filePart = hashAt === -1 ? raw : raw.slice(0, hashAt);
    const fragment = hashAt === -1 ? '' : decodeURIComponent(raw.slice(hashAt + 1));
    const target = filePart ? decodeURIComponent(filePart) : '';
    const resolved = target ? path.resolve(path.dirname(abs), target) : abs;
    if (!fs.existsSync(resolved)) {
      failures.push(`${rel}: missing local link ${raw}`);
      continue;
    }
    if (fragment && resolved.endsWith('.md') && fs.statSync(resolved).isFile() &&
        !anchorsOf(resolved).has(fragment.toLowerCase())) {
      failures.push(`${rel}: link ${raw} names a heading that does not exist`);
    }
  }
}

const requiredCommandStarts = [
  ['README.md', '```sh\ncd server\nnpm ci'],
  ['README.md', '```sh\ncd flutter_app\nflutter pub get --enforce-lockfile'],
  ['CONTRIBUTING.md', '```sh\ncd server\nnpm ci'],
  ['CONTRIBUTING.md', '```sh\ncd flutter_app\nflutter pub get --enforce-lockfile'],
  ['docs/ARCHITECTURE.md', '```sh\ncd server\nnpm run openapi:check'],
  ['DEPLOYMENT.md', '```sh\ncd /srv/simpastil\n./scripts/backup.sh'],
  ['DEPLOYMENT.md', '```sh\ncd /srv/simpastil\ndocker compose'],
];
for (const [rel, start] of requiredCommandStarts) {
  const text = fs.readFileSync(path.join(root, rel), 'utf8');
  if (!text.includes(start)) failures.push(`${rel}: command is missing its documented working directory`);
}
if (failures.length) {
  for (const failure of failures) process.stderr.write(`FAIL: ${failure}\n`);
  process.exit(1);
}
process.stdout.write(`checked ${files.length} Markdown files\n`);
NODE

scan_files=()
for file in "${entry_files[@]}"; do scan_files+=("$root/$file"); done

if grep -Ein -- '-----BEGIN (RSA )?PRIVATE KEY-----|\beyJ[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{12,}|\bsk_(live|test)_[A-Za-z0-9]+' "${scan_files[@]}"; then
  fail 'entry documents contain a raw key/token-like example'
fi
# Published contact addresses are allowed only for the project's security
# contact, which must be a role address or a hosted reporting link in
# SECURITY.md; every other document uses placeholders.
mail_files=()
for file in "${entry_files[@]}"; do
  [[ "$file" == SECURITY.md ]] || mail_files+=("$root/$file")
done
if grep -Ein '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' "${mail_files[@]}"; then
  fail 'entry documents contain a literal email address; use a neutral placeholder'
fi
if grep -Ein 'DATABASE_URL[[:space:]]*=[[:space:]]*[^[:space:]]*(postgres|simpastil_user)@' "${scan_files[@]}"; then
  fail 'entry documents show a privileged or ambiguous runtime database URL'
fi
if grep -Ein 'curl[[:space:]].*https?://[^/[:space:]]+/?$' "$root/DEPLOYMENT.md"; then
  fail 'deployment docs must not describe the bare origin as an API health endpoint'
fi

# Documentation must not record a developer's absolute home path. The
# documented service account /home/simpastil is an operator example.
if grep -rnE '/(home|Users)/[A-Za-z_][A-Za-z0-9_.-]*/' "${scan_files[@]}" | grep -v '/home/simpastil/'; then
  fail 'documentation contains an absolute home-directory path; use a repository-relative path or <repo>'
fi

printf 'PASS: documentation links and anchors, required commands, and privacy patterns\n'
