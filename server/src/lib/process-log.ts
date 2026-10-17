/**
 * Process-level log lines (startup, shutdown, background jobs, one-shot commands).
 *
 * Each line is one JSON object with a fixed event name and only bounded,
 * non-identifying fields, matching the logging contract in docs/ARCHITECTURE.md.
 * Callers must never pass error objects, identifiers, or configuration values.
 */
export type ProcessLogFields = Readonly<Record<string, string | number | boolean | undefined>>;

export function logProcessEvent(
  level: 'info' | 'error',
  event: string,
  fields: ProcessLogFields = {},
): void {
  const line = JSON.stringify({ event, ...fields });
  if (level === 'error') console.error(line);
  else console.log(line);
}
