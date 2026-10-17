import { describe, expect, it } from 'vitest';
import { ApiError } from '../modules/shared/api-error.js';
import { LogsQuerySchema } from '../modules/dose_logs/dose_logs.schema.js';
import { parseIsoDate } from './iso-date.js';

describe('parseIsoDate', () => {
  it('accepts a real leap day without normalizing it', () => {
    expect(parseIsoDate('2024-02-29')).toBe('2024-02-29');
  });

  it.each(['2025-02-29', '2026-04-31', '2026-00-10', '2026-12-00'])('rejects impossible date %s', (value) => {
    expect(() => parseIsoDate(value)).toThrow();
  });

  it.each([
    '2024-02-29T00:00:00.000Z',
    '2024-02-29T00:00:00+02:00',
    ' 2024-02-29',
    '2024-2-09',
  ])('rejects timezone-normalized or non-canonical input %s', (value) => {
    expect(() => parseIsoDate(value)).toThrow();
  });

  it('maps a semantic parser failure to a validation response instead of an internal error', () => {
    let error: unknown;
    try {
      parseIsoDate('2026-04-31');
    } catch (caught) {
      error = caught;
    }
    expect(ApiError.fromUnknown(error).statusCode).toBe(400);
    expect(ApiError.fromUnknown(error).code).toBe('VALIDATION_ERROR');
  });

  it('keeps conflict revisions as canonical decimal strings beyond JavaScript safe integers', () => {
    const largeRevision = '9007199254740993';
    const response = new ApiError(409, 'CONFLICT_STALE_UPDATE', 'stale update', {
      details: { currentRevision: largeRevision },
    }).toResponse('corr-123');
    expect(response.error.details).toEqual({ currentRevision: largeRevision });

    const unsafeNumber = new ApiError(409, 'CONFLICT_STALE_UPDATE', 'stale update', {
      details: { currentRevision: 9007199254740993 },
    }).toResponse('corr-123');
    expect(unsafeNumber.error.details).toEqual({});
  });

  it('rejects reversed ranges while accepting equal and forward ranges', () => {
    expect(LogsQuerySchema.safeParse({ from: '2026-05-02', to: '2026-05-01' }).success).toBe(false);
    expect(LogsQuerySchema.safeParse({ from: '2026-05-01', to: '2026-05-01' }).success).toBe(true);
    expect(LogsQuerySchema.safeParse({ from: '2026-05-01', to: '2026-05-02' }).success).toBe(true);
  });
});
