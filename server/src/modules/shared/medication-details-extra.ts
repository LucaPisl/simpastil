import { z } from 'zod';

// The optional limits, expiry date and contacts of a medication (capability
// contracts.medicationDetailsExtra 1). Every field is nullable and optional:
// absent on an update means "leave what is stored", null clears it.
//
// The phone numbers and the people and places behind them are personal data.
// They are stored and synced like any other medication field and must never be
// written to a log, an error message or a metric (docs/ARCHITECTURE.md).

export const PRN_MAX_PER_24H_MAX = 48;
export const PRN_MIN_GAP_MINUTES_MAX = 2880;
export const CONTACT_NAME_MAX = 120;
export const CONTACT_PHONE_MIN = 3;
export const CONTACT_PHONE_MAX = 40;

// Digits and the punctuation people type in a number. The database check
// pills_*_phone_check uses the same class, so a value that passes here is
// never rejected by it.
export const CONTACT_PHONE_PATTERN = /^[0-9+()./#* -]{3,40}$/;

/** The same fields as a list, for the "at least one field" update check. */
export const MEDICATION_DETAILS_EXTRA_KEYS = [
  'prnMaxPer24h', 'prnMinGapMinutes', 'expiresOn',
  'prescriberName', 'prescriberPhone', 'pharmacyName', 'pharmacyPhone',
] as const;

/** A valid Gregorian local date, `YYYY-MM-DD`, from year 0001. */
export const ExpiresOnSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((value) => {
  if (value.startsWith('0000-')) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}, 'must be a valid Gregorian date (YYYY-MM-DD)');

const contactName = z.string().trim().min(1).max(CONTACT_NAME_MAX);
const contactPhone = z.string().trim().regex(CONTACT_PHONE_PATTERN, 'must be a phone number');

export const medicationDetailsExtraFields = {
  prnMaxPer24h: z.number().int().min(1).max(PRN_MAX_PER_24H_MAX).nullable().optional(),
  prnMinGapMinutes: z.number().int().min(1).max(PRN_MIN_GAP_MINUTES_MAX).nullable().optional(),
  expiresOn: ExpiresOnSchema.nullable().optional(),
  prescriberName: contactName.nullable().optional(),
  prescriberPhone: contactPhone.nullable().optional(),
  pharmacyName: contactName.nullable().optional(),
  pharmacyPhone: contactPhone.nullable().optional(),
};
