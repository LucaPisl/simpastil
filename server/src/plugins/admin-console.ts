import fp from 'fastify-plugin';
import { createHash } from 'node:crypto';
import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import type { FastifyReply, FastifyRequest } from 'fastify';

/**
 * Response headers for every non-console response (the JSON API, errors and
 * the not-found body). The API never renders HTML, so nothing may load.
 * HSTS is deliberately absent: only the TLS terminator knows whether the
 * connection is HTTPS.
 */
export const API_SECURITY_HEADERS: Readonly<Record<string, string>> = Object.freeze({
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'no-referrer',
  'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
});

/** Response headers for the admin console (HTML, scripts, styles). */
export const ADMIN_CONSOLE_SECURITY_HEADERS: Readonly<Record<string, string>> = Object.freeze({
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'no-referrer',
  'content-security-policy':
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; "
    + "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'; object-src 'none'; "
    + "manifest-src 'self'",
  'permissions-policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()',
  'cross-origin-opener-policy': 'same-origin',
});

const CONTENT_TYPES: Readonly<Record<string, string>> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
};

/** Built output is a few hundred kilobytes; refuse anything that is not. */
const MAX_FILES = 512;
const MAX_FILE_BYTES = 8 * 1024 * 1024;

interface ConsoleFile {
  body: Buffer;
  contentType: string;
  etag: string;
  cacheControl: string;
}

async function* walk(root: string, relative = ''): AsyncGenerator<string> {
  const entries = await readdir(path.join(root, relative), { withFileTypes: true });
  for (const entry of entries) {
    // Dotfiles and source maps are never part of the served surface.
    if (entry.name.startsWith('.') || entry.name.endsWith('.map')) continue;
    const next = relative === '' ? entry.name : `${relative}/${entry.name}`;
    if (entry.isDirectory()) yield* walk(root, next);
    else if (entry.isFile()) yield next;
  }
}

/**
 * Loads the built console once. Serving a fixed in-memory allowlist (instead of
 * resolving request paths against the disk) makes path traversal impossible by
 * construction: a request either matches a registered route or is a 404.
 */
export async function loadAdminConsole(directory: string): Promise<Map<string, ConsoleFile> | undefined> {
  const root = path.resolve(directory);
  try {
    if (!(await stat(path.join(root, 'index.html'))).isFile()) return undefined;
  } catch {
    return undefined;
  }
  const files = new Map<string, ConsoleFile>();
  for await (const relative of walk(root)) {
    if (files.size >= MAX_FILES) throw new Error('admin console directory has too many files');
    const absolute = path.join(root, relative);
    if ((await stat(absolute)).size > MAX_FILE_BYTES) {
      throw new Error('admin console directory contains an oversized file');
    }
    const body = await readFile(absolute);
    const extension = path.extname(relative).toLowerCase();
    const hashed = relative.startsWith('assets/');
    files.set(`/${relative}`, {
      body,
      contentType: CONTENT_TYPES[extension] ?? 'application/octet-stream',
      etag: `"${createHash('sha256').update(body).digest('base64url').slice(0, 27)}"`,
      // Vite content-hashes everything under assets/, so it can be cached forever.
      cacheControl: hashed ? 'public, max-age=31536000, immutable' : 'no-cache',
    });
  }
  return files;
}

export interface AdminConsoleOptions {
  /** Directory holding the built console. Undefined or missing disables it. */
  directory?: string | undefined;
}

export default fp(async (fastify, options: AdminConsoleOptions) => {
  // Everything that is not the console carries the strict API header set.
  // The console handler sets its own set first; those are never overwritten.
  fastify.addHook('onSend', async (_request, reply) => {
    if (reply.hasHeader('content-security-policy')) return;
    for (const [name, value] of Object.entries(API_SECURITY_HEADERS)) reply.header(name, value);
  });

  if (!options.directory) return;
  const files = await loadAdminConsole(options.directory);
  if (!files) {
    fastify.log.warn('ADMIN_CONSOLE_DIR has no index.html; the admin console is not served by the API');
    return;
  }

  const serve = (file: ConsoleFile) => (request: FastifyRequest, reply: FastifyReply) => {
    for (const [name, value] of Object.entries(ADMIN_CONSOLE_SECURITY_HEADERS)) reply.header(name, value);
    reply.header('cache-control', file.cacheControl);
    reply.header('etag', file.etag);
    if (request.headers['if-none-match'] === file.etag) return reply.code(304).send();
    return reply.type(file.contentType).send(file.body);
  };

  // GET routes also answer HEAD (Fastify exposes HEAD for them). No other
  // method is registered, so POST and friends fall through to the API 404.
  for (const [route, file] of files) {
    // The console can never shadow the API namespace.
    if (route === '/api' || route.startsWith('/api/')) continue;
    fastify.get(route, { config: { adminConsole: true } }, serve(file));
    if (route === '/index.html') fastify.get('/', { config: { adminConsole: true } }, serve(file));
  }
  fastify.log.info('admin console served by the API');
}, { name: 'admin-console' });

declare module 'fastify' {
  interface FastifyContextConfig {
    adminConsole?: boolean;
  }
}
