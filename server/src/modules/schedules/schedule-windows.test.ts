import { describe, expect, it } from 'vitest';
import {
  CreateScheduleSchema,
  LegacyRepairDocumentSchema,
  ScheduleDocumentSchema,
  UpdateScheduleSchema,
} from './schedules.schema.js';
import {
  daysBetweenLocalDates,
  intervalIncludes,
  usesScheduleWindows,
  windowIncludes,
} from './schedule-windows.js';

const base = {
  mutationId: '11111111-1111-4111-8111-111111111111',
  hour: 8,
  minute: 0,
  timeZone: 'Europe/Bucharest',
};

describe('interval and window rules', () => {
  it('counts whole calendar days across month, leap day and year boundaries', () => {
    expect(daysBetweenLocalDates('2024-02-28', '2024-03-01')).toBe(2);
    expect(daysBetweenLocalDates('2025-12-31', '2026-01-01')).toBe(1);
    expect(daysBetweenLocalDates('2026-03-10', '2026-03-01')).toBe(-9);
  });

  it('matches D >= anchor with a multiple of everyDays', () => {
    expect(intervalIncludes(3, '2026-03-01', '2026-03-01')).toBe(true);
    expect(intervalIncludes(3, '2026-03-01', '2026-03-04')).toBe(true);
    expect(intervalIncludes(3, '2026-03-01', '2026-03-05')).toBe(false);
    expect(intervalIncludes(3, '2026-03-01', '2026-02-26')).toBe(false);
    expect(intervalIncludes(1, '2026-03-01', '2026-03-02')).toBe(true);
  });

  it('applies both window bounds inclusively and treats null as open', () => {
    const window = { startDate: '2026-06-03', endDate: '2026-06-05' };
    expect(windowIncludes(window, '2026-06-02')).toBe(false);
    expect(windowIncludes(window, '2026-06-03')).toBe(true);
    expect(windowIncludes(window, '2026-06-05')).toBe(true);
    expect(windowIncludes(window, '2026-06-06')).toBe(false);
    expect(windowIncludes({ startDate: null, endDate: null }, '1999-01-01')).toBe(true);
  });

  it('flags only interval or dated routines as using the windows', () => {
    expect(usesScheduleWindows({ frequency: 'daily' })).toBe(false);
    expect(usesScheduleWindows({ frequency: 'weekly', everyDays: null, startDate: null })).toBe(false);
    expect(usesScheduleWindows({ frequency: 'interval' })).toBe(true);
    expect(usesScheduleWindows({ frequency: 'daily', endDate: '2026-01-01' })).toBe(true);
  });
});

describe('schedule shape validation', () => {
  it('accepts an interval with everyDays and anchorDate', () => {
    expect(CreateScheduleSchema.safeParse({
      ...base, frequency: 'interval', everyDays: 3, anchorDate: '2026-03-01',
    }).success).toBe(true);
  });

  it.each([
    ['interval without everyDays', { frequency: 'interval', anchorDate: '2026-03-01' }],
    ['interval without anchorDate', { frequency: 'interval', everyDays: 3 }],
    ['interval with weekdays', { frequency: 'interval', everyDays: 3, anchorDate: '2026-03-01', frequencyDays: [1] }],
    ['everyDays of zero', { frequency: 'interval', everyDays: 0, anchorDate: '2026-03-01' }],
    ['everyDays above the ceiling', { frequency: 'interval', everyDays: 36501, anchorDate: '2026-03-01' }],
    ['daily with everyDays', { frequency: 'daily', everyDays: 2 }],
    ['weekly with anchorDate', { frequency: 'weekly', frequencyDays: [1], anchorDate: '2026-03-01' }],
    ['prn with a startDate', { frequency: 'prn', startDate: '2026-03-01' }],
    ['prn with an endDate', { frequency: 'prn', endDate: '2026-03-01' }],
    ['endDate before startDate', { frequency: 'daily', startDate: '2026-03-02', endDate: '2026-03-01' }],
    ['an impossible calendar date', { frequency: 'daily', startDate: '2026-02-30' }],
    ['year zero', { frequency: 'daily', startDate: '0000-01-01' }],
  ])('rejects %s', (_name, extra) => {
    expect(CreateScheduleSchema.safeParse({ ...base, ...extra }).success).toBe(false);
  });

  it('accepts a window on any non-prn frequency and endDate equal to startDate', () => {
    expect(CreateScheduleSchema.safeParse({
      ...base, frequency: 'custom', frequencyDays: [1, 3], startDate: '2026-03-01', endDate: '2026-03-01',
    }).success).toBe(true);
  });

  it('keeps an older document and request valid (the new fields default to null)', () => {
    const parsed = ScheduleDocumentSchema.parse({
      hour: 8, minute: 0, frequency: 'daily', frequencyDays: null, isActive: true, timeZone: 'Europe/Bucharest',
    });
    expect(parsed).toMatchObject({ everyDays: null, anchorDate: null, startDate: null, endDate: null });
    expect(CreateScheduleSchema.safeParse({ ...base, frequency: 'daily' }).success).toBe(true);
  });

  it('lets a PATCH clear a field with an explicit null and counts it as a change', () => {
    const parsed = UpdateScheduleSchema.parse({
      mutationId: base.mutationId, baseRevision: '2', endDate: null,
    });
    expect(parsed.endDate).toBeNull();
    expect(UpdateScheduleSchema.safeParse({ mutationId: base.mutationId, baseRevision: '2' }).success).toBe(false);
  });

  it('keeps legacy repair on the original four frequencies and no window', () => {
    const doc = { hour: 8, minute: 0, frequencyDays: null, isActive: true, timeZone: 'Europe/Bucharest' };
    expect(LegacyRepairDocumentSchema.safeParse({ ...doc, frequency: 'daily' }).success).toBe(true);
    expect(LegacyRepairDocumentSchema.safeParse({
      ...doc, frequency: 'interval', everyDays: 2, anchorDate: '2026-03-01',
    }).success).toBe(false);
    expect(LegacyRepairDocumentSchema.safeParse({ ...doc, frequency: 'daily', startDate: '2026-03-01' }).success).toBe(false);
  });
});
