/**
 * Process-level log lines (startup, shutdown, background jobs, one-shot commands).
 *
 * Each line is one JSON object with a fixed event name, a fixed English
 * sentence (`msg`) and only bounded, non-identifying fields, matching the
 * logging contract in docs/ARCHITECTURE.md. Callers must never pass error
 * objects, identifiers, or configuration values: report a failure with
 * `logProcessFailure`, which keeps only the allowlisted cause fields.
 */
import {
  CAUSE_FIELD_NAMES,
  describeCauseText,
  describeFailure,
  sanitizeCauseField,
  type SafeCause,
} from './failure-cause.js';

export type ProcessLogFields = Readonly<Record<string, string | number | boolean | undefined>>;

const PROCESS_ROLES = ['api', 'outbox', 'migrate', 'provision', 'command'] as const;
export type ProcessRole = (typeof PROCESS_ROLES)[number];

const CATEGORY_RE = /^[a-z][a-z_]{0,40}$/;
const EVENT_RE = /^[a-z][a-z0-9_.]{0,60}$/;

/** `base (first; second)`, leaving out whatever is missing. */
function withDetails(base: string, ...details: (string | undefined)[]): string {
  const present = details.filter((detail): detail is string => detail !== undefined);
  return present.length === 0 ? base : `${base} (${present.join('; ')})`;
}

interface SentenceInput {
  cause: string | undefined;
  category: string | undefined;
  role: string | undefined;
}

/** One sentence per known event; unknown events fall back to a wording of their name. */
const SENTENCES: Readonly<Record<string, (input: SentenceInput) => string>> = {
  'process.shutdown_started': () => 'Shutdown requested; finishing active work before exiting',
  'process.crashed': ({ cause, role }) => withDetails(
    `The ${role ?? 'server'} process stopped on an unhandled error and is exiting`, cause),
  'outbox.worker_start_failed': ({ cause }) => withDetails('The outbox worker could not start', cause),
  'outbox.worker_run_failed': ({ cause }) => withDetails('The outbox worker stopped because its delivery loop failed', cause),
  'outbox.idle_no_smtp': () => 'No SMTP host is configured, so the outbox worker is idle and will not send mail',
  'outbox.sent': () => 'A queued message was delivered',
  'outbox.retry_scheduled': ({ category, cause }) => withDetails(
    'Delivering a queued message failed; a retry is scheduled', category, cause),
  'outbox.failed_permanent': ({ category, cause }) => withDetails(
    'Delivering a queued message failed for good; it will not be retried', category, cause),
  'outbox.expired': () => 'A queued message expired before it could be delivered',
  'outbox.finalization_failed': ({ category, cause }) => withDetails(
    'Could not record the result of a delivery attempt', category, cause),
  'provision.runtime_posture_verified': () => 'The runtime database roles are least-privilege',
  'provision.runtime_roles_ready': () => 'The runtime database roles are provisioned',
  'provision.command_failed': ({ cause }) => withDetails('The provisioning command failed', cause),
  'token_gc.tenant_purge_failed': ({ cause }) => withDetails(
    'Expired-token cleanup failed for one account; continuing with the others', cause),
  'token_gc.periodic_purge_failed': ({ cause }) => withDetails(
    'Periodic expired-token cleanup failed; it will try again at the next interval', cause),
  'token_gc.initial_purge_failed': ({ cause }) => withDetails(
    'Startup expired-token cleanup failed; it will try again at the next interval', cause),
  'deployment_manifest.export_failed': ({ cause }) => withDetails('Could not export the deployment manifest', cause),
  'premigrate_backup.failed': ({ cause }) => withDetails(
    'The backup before the migration failed, so the migration was not started', cause),
  'scheduled_backup.started': () => 'The scheduled backup service started',
  'scheduled_backup.disabled': () => 'Scheduled backups are switched off; the service stays idle',
  'scheduled_backup.created': () => 'A scheduled backup was written',
  'scheduled_backup.failed': ({ cause }) => withDetails(
    'A scheduled backup failed; it will be tried again soon', cause),
  'scheduled_backup.crashed': ({ cause }) => withDetails(
    'The scheduled backup service could not start', cause),
};

function fallbackSentence(event: string): string {
  if (!EVENT_RE.test(event)) return 'Process event';
  const words = event.replace(/[._]+/g, ' ');
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/** Drops a caller-supplied `msg`/`event` and any cause field that fails its rule. */
function safeFields(fields: ProcessLogFields): ProcessLogFields {
  const safe: Record<string, string | number | boolean | undefined> = {};
  for (const [name, value] of Object.entries(fields)) {
    if (name === 'msg' || name === 'event') continue;
    if ((CAUSE_FIELD_NAMES as readonly string[]).includes(name)) {
      const checked = sanitizeCauseField(name, value);
      if (checked !== undefined) safe[name] = checked;
      continue;
    }
    safe[name] = value;
  }
  return safe;
}

function sentenceFor(event: string, fields: ProcessLogFields): string {
  const cause: SafeCause = {};
  for (const name of CAUSE_FIELD_NAMES) {
    const value = fields[name];
    if (typeof value === 'string') (cause as Record<string, string>)[name] = value;
  }
  const category = typeof fields['category'] === 'string' && CATEGORY_RE.test(fields['category'])
    ? fields['category']
    : undefined;
  const role = typeof fields['role'] === 'string' && (PROCESS_ROLES as readonly string[]).includes(fields['role'])
    ? fields['role']
    : undefined;
  const build = SENTENCES[event];
  return build
    ? build({ cause: describeCauseText(cause), category, role })
    : fallbackSentence(event);
}

export function logProcessEvent(
  level: 'info' | 'error',
  event: string,
  fields: ProcessLogFields = {},
): void {
  const safe = safeFields(fields);
  const line = JSON.stringify({ event, msg: sentenceFor(event, safe), ...safe });
  if (level === 'error') console.error(line);
  else console.log(line);
}

/** Logs a failure as an error event with its allowlisted cause and never its message. */
export function logProcessFailure(event: string, error: unknown, fields: ProcessLogFields = {}): void {
  logProcessEvent('error', event, { ...fields, ...describeFailure(error) });
}
