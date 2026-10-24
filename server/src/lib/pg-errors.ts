const UNIQUE_VIOLATION = '23505';
const MAX_CAUSE_DEPTH = 5;

/**
 * Drizzle 0.45 wraps driver failures in a `DrizzleQueryError` whose `.cause` is
 * the original `PostgresError`; earlier versions rethrew the driver error
 * itself. Look through the cause chain so SQLSTATE checks keep working either
 * way.
 */
export function sqlStateOf(error: unknown): string | undefined {
  let level: unknown = error;
  for (let depth = 0; depth < MAX_CAUSE_DEPTH; depth += 1) {
    if (typeof level !== 'object' || level === null) return undefined;
    const record = level as { code?: unknown; cause?: unknown };
    if (typeof record.code === 'string' && /^[0-9A-Z]{5}$/.test(record.code)) return record.code;
    level = record.cause;
  }
  return undefined;
}

export function isUniqueViolation(error: unknown): boolean {
  return sqlStateOf(error) === UNIQUE_VIOLATION;
}

/**
 * The violated constraint's name, read from the same cause chain: postgres-js
 * puts it on `constraint_name` of the original error. Never parse the message.
 */
export function constraintOf(error: unknown): string | undefined {
  let level: unknown = error;
  for (let depth = 0; depth < MAX_CAUSE_DEPTH; depth += 1) {
    if (typeof level !== 'object' || level === null) return undefined;
    const record = level as { constraint_name?: unknown; cause?: unknown };
    if (typeof record.constraint_name === 'string') return record.constraint_name;
    level = record.cause;
  }
  return undefined;
}
