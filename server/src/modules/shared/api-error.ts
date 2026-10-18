import { ZodError } from 'zod';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { ErrorCode, type ErrorCodeValue } from './errors.js';
import { CORRELATION_HEADER, createCorrelationId } from '../../plugins/correlation.js';
import { IsoDateError } from '../../lib/iso-date.js';
import { SafeLogger, type SafeLogFields } from '../../lib/safe-logger.js';
import { describeFailure } from '../../lib/failure-cause.js';

export type SafeErrorDetail = string | number | boolean | null;
export interface SafeCurrentEntity {
  entityType: 'profiles' | 'pills' | 'schedules';
  id: string;
  revision: string;
  [key: string]: SafeErrorDetail | number[];
}
export type SafeErrorDetails = Record<string, SafeErrorDetail | SafeCurrentEntity>;

export interface ApiErrorBody {
  error: {
    code: string;
    message: string;
    retryable: boolean;
    correlationId: string;
    details: SafeErrorDetails;
  };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CODE_RE = /^[A-Z][A-Z0-9_]{0,63}$/;
const DECIMAL_SIGNED_64_RE = /^(0|[1-9]\d{0,18})$/;
const MAX_SIGNED_64 = 9_223_372_036_854_775_807n;
const DETAIL_KEYS: Record<string, ReadonlySet<string>> = {
  [ErrorCode.RATE_LIMIT_EXCEEDED]: new Set(['retryAfter']),
  [ErrorCode.CONFLICT_DOSE_LOG]: new Set(['existingId']),
  [ErrorCode.CONFLICT_DUPLICATE]: new Set(['existingId', 'currentEntity']),
  [ErrorCode.RESOURCE_NOT_FOUND]: new Set(['currentEntity']),
  [ErrorCode.CONFLICT_STALE_UPDATE]: new Set(['existingId', 'currentRevision']),
  [ErrorCode.CONFLICT_REVISION]: new Set(['currentRevision', 'currentEntity']),
};

const CURRENT_ENTITY_CODES: ReadonlySet<string> = new Set([
  ErrorCode.CONFLICT_REVISION,
  ErrorCode.CONFLICT_DUPLICATE,
  ErrorCode.RESOURCE_NOT_FOUND,
]);

function safeRevision(value: unknown): value is string {
  return typeof value === 'string'
    && DECIMAL_SIGNED_64_RE.test(value)
    && BigInt(value) <= MAX_SIGNED_64;
}

function safeNullableText(value: unknown, maximum: number): value is string | null {
  return value === null || (typeof value === 'string' && value.length <= maximum);
}

function safeDeletedAt(value: unknown): value is string | null {
  return value === null
    || (typeof value === 'string' && value.length <= 40 && Number.isFinite(Date.parse(value)));
}

function safeCurrentEntity(value: unknown): SafeCurrentEntity | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const row = value as Record<string, unknown>;
  const id = row['id'];
  const revision = row['revision'];
  const deletedAt = row['deletedAt'];
  if (typeof id !== 'string' || !UUID_RE.test(id) || !safeRevision(revision) || !safeDeletedAt(deletedAt)) {
    return undefined;
  }

  if (row['entityType'] === 'profiles') {
    if (typeof row['name'] !== 'string' || row['name'].length < 1 || row['name'].length > 100
        || typeof row['avatarEmoji'] !== 'string' || row['avatarEmoji'].length < 1
        || row['avatarEmoji'].length > 32 || typeof row['isActive'] !== 'boolean') return undefined;
    return {
      entityType: 'profiles', id, revision, name: row['name'], avatarEmoji: row['avatarEmoji'],
      isActive: row['isActive'], deletedAt,
    };
  }

  // The reviewed details (amountPerUse, packageStrength, form,
  // legacyDosageReviewed) are deliberately left out of this echo. amountPerUse
  // is an object and SafeCurrentEntity carries flat scalars only, and echoing
  // the other three without it would let a conflict mark a medicine reviewed
  // while its amount stayed stale. A conflict means the server already holds a
  // revision the client has not pulled, so the pull that follows carries the
  // whole pill item and the details converge there.
  if (row['entityType'] === 'pills') {
    const profileId = row['profileId'];
    const currentStock = row['currentStock'];
    const lowStockThreshold = row['lowStockThreshold'];
    if (typeof profileId !== 'string' || !UUID_RE.test(profileId)
        || typeof row['name'] !== 'string' || row['name'].length < 1 || row['name'].length > 100
        || !safeNullableText(row['dosage'], 50) || !safeNullableText(row['notes'], 500)
        || !safeNullableText(row['color'], 7)
        || (currentStock !== null && !Number.isSafeInteger(currentStock))
        || (lowStockThreshold !== null
          && (!Number.isSafeInteger(lowStockThreshold) || (lowStockThreshold as number) < 0))
        || typeof row['isPrn'] !== 'boolean') return undefined;
    return {
      entityType: 'pills', id, revision, profileId, name: row['name'], dosage: row['dosage'],
      notes: row['notes'], color: row['color'], currentStock: currentStock as number | null,
      lowStockThreshold: lowStockThreshold as number | null, isPrn: row['isPrn'], deletedAt,
    };
  }

  if (row['entityType'] === 'schedules') {
    const pillId = row['pillId'];
    const days = row['frequencyDays'];
    const status = row['timeZoneStatus'];
    const timeZone = row['timeZone'];
    const validDays = days === null || (Array.isArray(days) && days.length <= 7
      && days.every((day) => Number.isInteger(day) && (day as number) >= 1 && (day as number) <= 7));
    if (typeof pillId !== 'string' || !UUID_RE.test(pillId)
        || !Number.isInteger(row['hour']) || (row['hour'] as number) < 0 || (row['hour'] as number) > 23
        || !Number.isInteger(row['minute']) || (row['minute'] as number) < 0 || (row['minute'] as number) > 59
        || !['daily', 'weekly', 'custom', 'prn'].includes(row['frequency'] as string)
        || !validDays || typeof row['isActive'] !== 'boolean'
        || (status !== 'known' && status !== 'legacy_unknown')
        || (status === 'known' && (typeof timeZone !== 'string' || timeZone.length > 128))
        || (status === 'legacy_unknown' && timeZone !== null)) return undefined;
    return {
      entityType: 'schedules', id, revision, pillId, hour: row['hour'] as number,
      minute: row['minute'] as number,
      frequency: row['frequency'] as 'daily' | 'weekly' | 'custom' | 'prn',
      frequencyDays: days as number[] | null, isActive: row['isActive'],
      timeZoneStatus: status, timeZone: timeZone as string | null, deletedAt,
    };
  }
  return undefined;
}

function safeDetails(code: string, details: unknown): SafeErrorDetails {
  if (!details || typeof details !== 'object' || Array.isArray(details)) return {};
  const allowed = DETAIL_KEYS[code];
  if (!allowed) return {};
  const result: SafeErrorDetails = {};
  for (const [key, value] of Object.entries(details)) {
    if (!allowed.has(key)) continue;
    if (key === 'existingId' && typeof value === 'string' && UUID_RE.test(value)) result[key] = value;
    else if (key === 'currentRevision' && safeRevision(value)) result[key] = value;
    else if (key === 'currentEntity' && CURRENT_ENTITY_CODES.has(code)) {
      const current = safeCurrentEntity(value);
      if (current) result[key] = current;
    }
    else if (key === 'retryAfter' && typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= 86_400) result[key] = value;
  }
  return result;
}

function isKnownCode(value: unknown): value is ErrorCodeValue {
  return typeof value === 'string' && Object.values(ErrorCode).includes(value as ErrorCodeValue);
}

function retryableFor(statusCode: number): boolean {
  return statusCode === 408 || statusCode === 429 || statusCode >= 500;
}

function safeMessageFor(statusCode: number, error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (statusCode === 400 || statusCode === 422) return 'Request validation failed';
  if (statusCode === 401 || statusCode === 403) return 'Unauthorized';
  if (statusCode === 404) return 'Resource not found';
  if (statusCode === 409) return 'Request conflicts with the current resource';
  if (statusCode === 429) return 'Too Many Requests';
  return 'Internal Server Error';
}

export class ApiError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
    options: { retryable?: boolean; details?: unknown; logFields?: SafeLogFields } = {},
  ) {
    super(message);
    this.name = 'ApiError';
    this.retryable = options.retryable ?? retryableFor(statusCode);
    this.details = safeDetails(code, options.details);
    this.logFields = options.logFields ?? {};
  }

  readonly retryable: boolean;
  readonly details: SafeErrorDetails;
  /** Extra allowlisted fields for the server log only; never sent to the client. */
  readonly logFields: SafeLogFields;

  static validation(logFields: SafeLogFields = {}): ApiError {
    return new ApiError(400, ErrorCode.VALIDATION_ERROR, 'Request validation failed', {
      retryable: false,
      logFields,
    });
  }

  static fromUnknown(error: unknown): ApiError {
    if (error instanceof ApiError) return error;
    if (error instanceof ZodError || (error && typeof error === 'object' && (error as { name?: unknown }).name === 'ZodError')) {
      return ApiError.validation(describeFailure(error));
    }
    if (error instanceof IsoDateError) {
      return ApiError.validation({ ...describeFailure(error), causeKind: 'validation' });
    }

    const candidate = error as { statusCode?: unknown; code?: unknown; retryAfter?: unknown } | null;
    const statusCode = typeof candidate?.statusCode === 'number'
      && Number.isInteger(candidate.statusCode)
      && candidate.statusCode >= 400
      && candidate.statusCode <= 599
      ? candidate.statusCode
      : 500;
    let code: string = ErrorCode.INTERNAL;
    if (isKnownCode(candidate?.code)) code = candidate.code;
    else if (statusCode === 400 || statusCode === 422) code = ErrorCode.VALIDATION_ERROR;
    else if (statusCode === 404) code = ErrorCode.RESOURCE_NOT_FOUND;
    else if (statusCode === 429) code = ErrorCode.RATE_LIMIT_EXCEEDED;
    const retryAfter = typeof candidate?.retryAfter === 'number' ? candidate.retryAfter : undefined;
    // The client only ever sees the generic message above; the log gets the
    // allowlisted reason so a 500 can be diagnosed without the exception text.
    const cause = describeFailure(error);
    const logFields: SafeLogFields = statusCode >= 500
      ? cause
      : { ...(cause.causeCode ? { causeCode: cause.causeCode } : {}), ...(cause.errorClass ? { errorClass: cause.errorClass } : {}) };
    return new ApiError(statusCode, CODE_RE.test(code) ? code : ErrorCode.INTERNAL, safeMessageFor(statusCode, error), {
      retryable: retryableFor(statusCode),
      logFields,
      ...(retryAfter === undefined ? {} : { details: { retryAfter } }),
    });
  }

  toResponse(correlationId: string): ApiErrorBody {
    return {
      error: {
        code: this.code,
        message: this.message,
        retryable: this.retryable,
        correlationId,
        details: this.details,
      },
    };
  }
}

export function serializeApiError(error: unknown, correlationId: string): ApiErrorBody {
  return ApiError.fromUnknown(error).toResponse(correlationId);
}

export function sendApiError(
  reply: FastifyReply,
  request: FastifyRequest,
  error: unknown,
): FastifyReply {
  const correlationId = request.correlationId || createCorrelationId();
  reply.header(CORRELATION_HEADER, correlationId);
  const apiError = ApiError.fromUnknown(error);
  const logger = new SafeLogger({
    info: (record) => request.log.info(record),
    warn: (record) => request.log.warn(record),
    error: (record) => request.log.error(record),
  });
  const fields: SafeLogFields = {
    ...apiError.logFields,
    correlationId,
    method: request.method,
    statusCode: apiError.statusCode,
    errorCode: apiError.code,
    retryable: apiError.retryable,
    ...(request.routeOptions.url ? { route: request.routeOptions.url } : {}),
  };
  logger.error('request.error', fields);
  return reply.status(apiError.statusCode).send(apiError.toResponse(correlationId));
}
