import { z } from 'zod';

const ISO_DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

export class IsoDateError extends Error {
  readonly code = 'INVALID_DATE';

  constructor() {
    super('Invalid calendar date');
    this.name = 'IsoDateError';
  }
}

/**
 * Validates a date-only ISO value without allowing JavaScript Date to roll an
 * impossible component into the following month. The original string is
 * returned so callers cannot accidentally introduce a timezone conversion.
 */
export function parseIsoDate(value: string): string {
  const match = ISO_DATE_RE.exec(value);
  if (!match) throw new IsoDateError();

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) {
    throw new IsoDateError();
  }

  // Start from a date whose time is already UTC, then set the full year in a
  // single operation. This also avoids Date.UTC's special handling of years
  // 0–99 as 1900–1999.
  const candidate = new Date(0);
  candidate.setUTCHours(0, 0, 0, 0);
  candidate.setUTCFullYear(year, month - 1, day);
  if (
    candidate.getUTCFullYear() !== year
    || candidate.getUTCMonth() !== month - 1
    || candidate.getUTCDate() !== day
  ) {
    throw new IsoDateError();
  }
  return value;
}

export function isIsoDate(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  try {
    parseIsoDate(value);
    return true;
  } catch {
    return false;
  }
}

export const IsoDateSchema = z.string().refine(isIsoDate, {
  message: 'Invalid calendar date',
});
