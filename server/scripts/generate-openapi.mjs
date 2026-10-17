import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';
import { openApiDocument, openApiRouteInventory } from '../dist/contracts/openapi.js';

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const outputPath = resolve(scriptDirectory, '../openapi/openapi.json');
const checkOnly = process.argv[2] === '--check';
if (process.argv.length > 3 || (process.argv[2] !== undefined && !checkOnly)) {
  throw new Error('Usage: node scripts/generate-openapi.mjs [--check]');
}

function sortObjectKeys(value) {
  if (Array.isArray(value)) return value.map(sortObjectKeys);
  if (value === null || typeof value !== 'object') return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortObjectKeys(value[key])]));
}

async function routeFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(entries.sort((a, b) => a.name.localeCompare(b.name)).map(async (entry) => {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) return routeFiles(path);
    return entry.isFile() && entry.name.endsWith('.routes.ts') ? [path] : [];
  }));
  return files.flat();
}

async function registeredRouteKeys() {
  const root = resolve(scriptDirectory, '../src/modules');
  const files = await routeFiles(root);
  const methods = new Set(['get', 'post', 'put', 'patch', 'delete', 'options', 'head']);
  const operations = [];
  for (const path of files) {
    const source = ts.createSourceFile(path, await readFile(path, 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    const visit = (node) => {
      if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
        const method = node.expression.name.text.toLowerCase();
        const routePath = node.arguments[0];
        if (methods.has(method) && routePath && ts.isStringLiteralLike(routePath) && routePath.text.startsWith('/')) {
          const normalized = routePath.text.replace(/:([A-Za-z0-9_]+)/g, '{$1}');
          const fullPath = normalized.startsWith('/api/v1/') ? normalized : `/api/v1${normalized}`;
          operations.push(`${method.toUpperCase()} ${fullPath}`);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  return operations.sort();
}

const inventoryKeys = openApiRouteInventory.map(({ method, path }) => `${method.toUpperCase()} ${path}`);
if (new Set(inventoryKeys).size !== inventoryKeys.length) {
  throw new Error('OpenAPI source contains duplicate route operations');
}
if (openApiRouteInventory.some(({ path }) => !path.startsWith('/api/v1/'))) {
  throw new Error('Every documented API route must remain under /api/v1');
}
const actualRouteKeys = await registeredRouteKeys();
const documentedRouteKeys = [...inventoryKeys].sort();
if (JSON.stringify(actualRouteKeys) !== JSON.stringify(documentedRouteKeys)) {
  const missing = actualRouteKeys.filter((operation) => !documentedRouteKeys.includes(operation));
  const extra = documentedRouteKeys.filter((operation) => !actualRouteKeys.includes(operation));
  throw new Error(`OpenAPI route inventory drifted from route registrations. Missing: ${missing.join(', ') || 'none'}; undocumented: ${extra.join(', ') || 'none'}`);
}

const document = `${JSON.stringify(sortObjectKeys(openApiDocument), null, 2)}\n`;
if (checkOnly) {
  let current;
  try {
    current = await readFile(outputPath, 'utf8');
  } catch {
    throw new Error('OpenAPI snapshot is missing; run npm run openapi:generate');
  }
  if (current !== document) throw new Error('OpenAPI snapshot is stale; run npm run openapi:generate');
  process.stdout.write('OpenAPI snapshot is current.\n');
} else {
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, document, 'utf8');
  process.stdout.write('Wrote server/openapi/openapi.json.\n');
}
