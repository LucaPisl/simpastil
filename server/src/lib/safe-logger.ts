import { isValidReleaseUrl, VERSION_RE } from '../modules/updates/release.js';
import {
  CAUSE_FIELD_NAMES,
  describeCauseText,
  sanitizeCauseField,
  type SafeCause,
} from './failure-cause.js';
import { isReadinessReason, READINESS_REASON_TEXT, type ReadinessReason } from './readiness-reason.js';

export const SAFE_LOG_EVENTS = [
  'request.error',
  'request.complete',
  'correlation.rejected',
  'update.available',
  'update.check_failed',
  'readiness.not_ready',
  'readiness.recovered',
] as const;
export type SafeLogEvent = (typeof SAFE_LOG_EVENTS)[number];

export interface SafeLogFields extends SafeCause {
  correlationId?: string;
  method?: string;
  route?: string;
  statusCode?: number;
  durationMs?: number;
  errorCode?: string;
  retryable?: boolean;
  syncComponent?: string;
  serverSequence?: string;
  currentServerVersion?: string;
  latestServerVersion?: string;
  latestClientBuild?: number;
  releaseUrl?: string;
  readinessReason?: ReadinessReason;
}

/** `msg` is a fixed English sentence built from the sanitized fields only. */
export type SafeLogRecord = { event: SafeLogEvent; msg: string } & SafeLogFields;

export interface SafeLogSink {
  info(record: SafeLogRecord): void;
  warn(record: SafeLogRecord): void;
  error(record: SafeLogRecord): void;
}

const SAFE_FIELD_NAMES: ReadonlySet<string> = new Set<keyof SafeLogFields>([
  'correlationId',
  'method',
  'route',
  'statusCode',
  'durationMs',
  'errorCode',
  'retryable',
  'syncComponent',
  'serverSequence',
  'currentServerVersion',
  'latestServerVersion',
  'latestClientBuild',
  'releaseUrl',
  'readinessReason',
  ...CAUSE_FIELD_NAMES,
]);
const CORRELATION_RE = /^[A-Za-z0-9][A-Za-z0-9._~-]{0,63}$/;
const METHOD_RE = /^(GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD)$/;
const ROUTE_RE = /^\/(?:api\/v\d+|health)(?:\/[A-Za-z0-9._:-]+)*$/;
const CODE_RE = /^[A-Z][A-Z0-9_]{0,63}$/;
const MAX_ROUTE_LENGTH = 128;
const SYNC_COMPONENT_RE = /^(account|stable|medicationBridge|medication)$/;
const SEQUENCE_RE = /^(0|[1-9]\d{0,18})$/;

export function isSafeLogEvent(value: unknown): value is SafeLogEvent {
  return typeof value === 'string' && (SAFE_LOG_EVENTS as readonly string[]).includes(value);
}

function sanitizeFields(fields: SafeLogFields | undefined): SafeLogFields {
  if (!fields || typeof fields !== 'object' || Array.isArray(fields)) return {};
  const safe: SafeLogFields = {};

  for (const [rawKey, rawValue] of Object.entries(fields as Record<string, unknown>)) {
    if (!SAFE_FIELD_NAMES.has(rawKey)) continue;
    const key = rawKey as keyof SafeLogFields;
    if ((CAUSE_FIELD_NAMES as readonly string[]).includes(key)) {
      const value = sanitizeCauseField(key, rawValue);
      if (value !== undefined) (safe as Record<string, string>)[key] = value;
      continue;
    }
    if (key === 'correlationId' && typeof rawValue === 'string' && CORRELATION_RE.test(rawValue)) safe.correlationId = rawValue;
    else if (key === 'method' && typeof rawValue === 'string' && METHOD_RE.test(rawValue)) safe.method = rawValue;
    else if (key === 'route' && typeof rawValue === 'string' && rawValue.length <= MAX_ROUTE_LENGTH && ROUTE_RE.test(rawValue)) safe.route = rawValue;
    else if (key === 'errorCode' && typeof rawValue === 'string' && CODE_RE.test(rawValue)) safe.errorCode = rawValue;
    else if (key === 'statusCode' && typeof rawValue === 'number' && Number.isSafeInteger(rawValue) && rawValue >= 100 && rawValue <= 599) safe.statusCode = rawValue;
    else if (key === 'durationMs' && typeof rawValue === 'number' && Number.isFinite(rawValue) && rawValue >= 0 && rawValue <= 86_400_000) safe.durationMs = Math.round(rawValue);
    else if (key === 'retryable' && typeof rawValue === 'boolean') safe.retryable = rawValue;
    else if (key === 'syncComponent' && typeof rawValue === 'string' && SYNC_COMPONENT_RE.test(rawValue)) safe.syncComponent = rawValue;
    else if (key === 'serverSequence' && typeof rawValue === 'string' && SEQUENCE_RE.test(rawValue)) safe.serverSequence = rawValue;
    else if ((key === 'currentServerVersion' || key === 'latestServerVersion') && typeof rawValue === 'string' && VERSION_RE.test(rawValue)) safe[key] = rawValue;
    else if (key === 'latestClientBuild' && typeof rawValue === 'number' && Number.isSafeInteger(rawValue) && rawValue > 0) safe.latestClientBuild = rawValue;
    else if (key === 'releaseUrl' && isValidReleaseUrl(rawValue)) safe.releaseUrl = rawValue;
    else if (key === 'readinessReason' && isReadinessReason(rawValue)) safe.readinessReason = rawValue;
  }
  return safe;
}

function routeClause(fields: SafeLogFields): string {
  if (fields.method && fields.route) return ` on ${fields.method} ${fields.route}`;
  if (fields.route) return ` on ${fields.route}`;
  return '';
}

/**
 * One fixed English sentence per event, assembled only from fields that have
 * already passed validation, so it can say what happened without ever
 * carrying free text. The JSON fields stay the machine-readable record.
 */
function sentenceFor(event: SafeLogEvent, fields: SafeLogFields): string {
  const cause = describeCauseText(fields);
  const causeClause = cause ? ` (${cause})` : '';
  switch (event) {
    case 'request.error': {
      const verdict = (fields.statusCode ?? 500) >= 500 ? 'Request failed' : 'Request rejected';
      const what = [fields.statusCode, fields.errorCode].filter((part) => part !== undefined).join(' ');
      return `${verdict}${what ? `: ${what}` : ''}${causeClause}${routeClause(fields)}`;
    }
    case 'request.complete': {
      const took = fields.durationMs === undefined ? '' : ` in ${fields.durationMs} ms`;
      return `Request completed${fields.statusCode ? `: ${fields.statusCode}` : ''}${routeClause(fields)}${took}`;
    }
    case 'correlation.rejected':
      return `Ignored an invalid correlation ID and issued a new one${routeClause(fields)}`;
    case 'update.available':
      return `A newer Simpastil release is available: ${fields.latestServerVersion ?? 'unknown'}`
        + ` (this server runs ${fields.currentServerVersion ?? 'unknown'})`;
    case 'update.check_failed':
      return `The update check failed${fields.errorCode ? ` (${fields.errorCode})` : ''}; it will try again later`;
    case 'readiness.not_ready': {
      const reason = fields.readinessReason
        ? READINESS_REASON_TEXT[fields.readinessReason]
        : 'the readiness check did not pass';
      return `Server is not ready: ${reason}${causeClause}`;
    }
    case 'readiness.recovered':
      return 'Server is ready again';
  }
}

function record(event: SafeLogEvent, fields: SafeLogFields | undefined): SafeLogRecord {
  const safe = sanitizeFields(fields);
  return { event, msg: sentenceFor(event, safe), ...safe };
}

export class SafeLogger {
  constructor(private readonly sink: SafeLogSink) {}

  info(event: SafeLogEvent, fields?: SafeLogFields): void {
    if (!isSafeLogEvent(event)) return;
    this.sink.info(record(event, fields));
  }

  warn(event: SafeLogEvent, fields?: SafeLogFields): void {
    if (!isSafeLogEvent(event)) return;
    this.sink.warn(record(event, fields));
  }

  error(event: SafeLogEvent, fields?: SafeLogFields): void {
    if (!isSafeLogEvent(event)) return;
    this.sink.error(record(event, fields));
  }
}

export { sanitizeFields as sanitizeSafeLogFields };
