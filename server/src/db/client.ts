import postgres, { type Sql } from 'postgres';
import { drizzle, type PostgresJsDatabase } from 'drizzle-orm/postgres-js';
import * as schema from './schema.js';
import type { DatabaseConfig } from '../config/app-config.js';

/**
 * postgres.js connection pool.
 *
 * Exposed so that route handlers can open transactions and call
 *   SET LOCAL app.current_user_id = '<uuid>'
 * before issuing queries, activating the Row-Level Security policies.
 *
 * Max pool size is 10 — sized for a single-host deployment. Tune via
 * POSTGRES_MAX_CONNECTIONS if the deployment changes.
 */
export type Db = PostgresJsDatabase<typeof schema> & { $client: Sql };

export interface DatabaseHandle {
  sql: Sql;
  db: Db;
}

/**
 * Construct a database handle from an already validated, role-specific
 * configuration record. Importing this module is intentionally side-effect
 * free: tests and application factories must be able to load route modules
 * without ambient DATABASE_URL state opening a connection pool.
 */
export function createDatabase(databaseConfig: DatabaseConfig): DatabaseHandle {
  let configuredUser: string;
  try {
    configuredUser = decodeURIComponent(new URL(databaseConfig.url).username);
  } catch {
    throw new Error('Database URL must be valid');
  }
  if (databaseConfig.role !== 'app_user' || configuredUser !== 'app_user') {
    throw new Error('The API database factory accepts only the app_user role');
  }

  const sql = postgres(databaseConfig.url, {
    max: databaseConfig.maxConnections,
    // Return JS Date objects for timestamp columns instead of strings.
    // This keeps the TypeScript types consistent with the schema definitions.
    types: {
      date: {
        to: 1184,
        from: [1082, 1083, 1114, 1184],
        serialize: (x: Date) => x.toISOString(),
        parse: (x: string) => new Date(x),
      },
    },
    // Fail fast in production if the connection can't be established.
    connect_timeout: 10,
    idle_timeout: 30,
    max_lifetime: 1800,
    // Prevent runaway queries from holding connections indefinitely.
    connection: { statement_timeout: 30_000 },
  });

  const db = drizzle(sql, { schema }) as Db;
  return { sql, db };
}
