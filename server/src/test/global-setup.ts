import { PostgreSqlContainer, StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import postgres from 'postgres';
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { generateTestKeyPair } from './helpers/key-helpers.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Module-level reference so teardown can stop the container.
let container: StartedPostgreSqlContainer;

export async function setup(): Promise<void> {
  // 1. Generate ephemeral RS256 keys and expose them via process.env
  //    so loadKeys() succeeds when auth.routes.ts calls it during buildApp().
  const { privateKey, publicKey } = generateTestKeyPair();
  process.env['JWT_PRIVATE_KEY'] = privateKey;
  process.env['JWT_PUBLIC_KEY']  = publicKey;

  if (!process.env['TOTP_ENC_KEY']) {
    process.env['TOTP_ENC_KEY'] = '0'.repeat(64);
  }
  // 2. Start the PostgreSQL container.
  const postgresImage = process.env['TEST_POSTGRES_IMAGE'] ?? 'postgres:16-alpine';
  // This fixture is disposable; avoid host disk-sync stalls during cleanup.
  // Keep PostgreSQL's durability settings enabled and bound temporary storage.
  container = await new PostgreSqlContainer(postgresImage)
    .withTmpFs({ '/var/lib/postgresql/data': 'rw,size=512m' })
    .start();

  const superUri = container.getConnectionUri();

  // 3. Run the journal-backed migration chain as the disposable superuser.
  //    This keeps the application harness on the same migration mechanism as
  //    production and exercises the 0012 role/RLS grants in every suite.
  const sql = postgres(superUri, { max: 1 });
  await migrate(drizzle(sql), { migrationsFolder: join(__dirname, '../db/migrations') });
  // Enable pgcrypto so __tests__/auth.service.test.ts can use digest() for
  // verifying that only token hashes (not raw tokens) are stored.
  await sql.unsafe(`CREATE EXTENSION IF NOT EXISTS pgcrypto;`);

  // 4. Set a password on app_user and grant CONNECT (the role is created by
  //    rls-policies.sql with PASSWORD NULL — we need a real password for the
  //    app_user connection string used by the RLS-enforced Drizzle instance).
  await sql.unsafe(`
    ALTER ROLE app_user PASSWORD 'testpass';
    GRANT CONNECT ON DATABASE "${container.getDatabase()}" TO app_user;
  `);
  await sql.end();

  // 5. Expose connection strings for all test workers.
  const appUri = superUri
    .replace(/\/\/[^:]+:[^@]+@/, '//app_user:testpass@')
    .replace(/\/[^/]+$/, `/${container.getDatabase()}`);
  process.env['TEST_DATABASE_URL_SUPER'] = superUri;
  process.env['TEST_DATABASE_URL_APP'] = appUri;
  process.env['DATABASE_URL'] = appUri;
  // Aliases used by the __tests__/ suite (legacy naming convention).
  process.env['DATABASE_URL_SUPER'] = superUri;
  process.env['DATABASE_URL_APP'] = appUri;
}

export async function teardown(): Promise<void> {
  await container?.stop();
}

export default setup;
