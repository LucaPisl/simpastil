import { isValidReleaseUrl, VERSION_RE } from '../modules/updates/release.js';

export const SAFE_LOG_EVENTS = [
  'request.error',
  'request.complete',
  'correlation.rejected',
  'update.available',
  'update.check_failed',
] as const;
export type SafeLogEvent = (typeof SAFE_LOG_EVENTS)[number];

export interface SafeLogFields {
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
}

export type SafeLogRecord = { event: SafeLogEvent } & SafeLogFields;

export interface SafeLogSink {
  info(record: SafeLogRecord): void;
  warn(record: SafeLogRecord): void;
  error(record: SafeLogRecord): void;
}

const SAFE_FIELD_NAMES = new Set<keyof SafeLogFields>([
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
    if (!SAFE_FIELD_NAMES.has(rawKey as keyof SafeLogFields)) continue;
    const key = rawKey as keyof SafeLogFields;
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
  }
  return safe;
}

export class SafeLogger {
  constructor(private readonly sink: SafeLogSink) {}

  info(event: SafeLogEvent, fields?: SafeLogFields): void {
    if (!isSafeLogEvent(event)) return;
    this.sink.info({ event, ...sanitizeFields(fields) });
  }

  warn(event: SafeLogEvent, fields?: SafeLogFields): void {
    if (!isSafeLogEvent(event)) return;
    this.sink.warn({ event, ...sanitizeFields(fields) });
  }

  error(event: SafeLogEvent, fields?: SafeLogFields): void {
    if (!isSafeLogEvent(event)) return;
    this.sink.error({ event, ...sanitizeFields(fields) });
  }
}

export { sanitizeFields as sanitizeSafeLogFields };
