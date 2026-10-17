/**
 * Pre-migration helper for existing prod servers.
 *
 * Run BEFORE drizzle-kit migrate when upgrading a server that already has users.
 * Generates a real random API key per user, writes hashes to a temp DB table
 * (migration_key_hashes), and outputs migrated-keys.csv with raw keys for admin
 * distribution.
 *
 * Usage:
 *   DATABASE_URL_SUPER=postgres://... npx tsx scripts/migrate-api-keys.ts
 *
 * The CSV columns: email, raw_api_key
 * Admin should: share keys with users, then revoke + re-issue clean keys via UI.
 */
import postgres from 'postgres';
import { loadDatabaseConfig, readRuntimeEnvironment } from '../src/config/app-config.js';
import { createHash, randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const databaseConfig = loadDatabaseConfig(readRuntimeEnvironment(), 'migrate');

const sql = postgres(databaseConfig.url, { max: databaseConfig.maxConnections });

try {
  const users = await sql<{ id: string; email: string }[]>`
    SELECT id, email FROM users
    WHERE NOT EXISTS (
      SELECT 1 FROM api_keys WHERE user_id = users.id
    )
  `.catch(() => [] as { id: string; email: string }[]);

  if (users.length === 0) {
    console.log('No users without API keys found. Nothing to do.');
    process.exit(0);
  }

  // Create temp table to pass hashes to the migration SQL
  await sql`
    CREATE TABLE IF NOT EXISTS migration_key_hashes (
      user_id UUID NOT NULL,
      key_hash TEXT NOT NULL
    )
  `;

  const rows: { email: string; rawKey: string }[] = [];

  for (const user of users) {
    const rawKey = randomBytes(32).toString('hex');
    const keyHash = createHash('sha256').update(rawKey).digest('hex');
    await sql`INSERT INTO migration_key_hashes (user_id, key_hash) VALUES (${user.id}, ${keyHash})`;
    rows.push({ email: user.email, rawKey });
  }

  const csv = ['email,raw_api_key', ...rows.map(r => `${r.email},${r.rawKey}`)].join('\n');
  writeFileSync('migrated-keys.csv', csv);

  console.log(`✓ Generated keys for ${users.length} user(s).`);
  console.log('✓ Hashes written to migration_key_hashes table.');
  console.log('✓ Raw keys written to migrated-keys.csv — distribute to users then delete this file.');
  console.log('→ Now run: drizzle-kit migrate');
} finally {
  await sql.end();
}
