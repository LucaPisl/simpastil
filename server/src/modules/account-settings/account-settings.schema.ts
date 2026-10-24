import { z } from 'zod';

/**
 * The single allowlist of account settings. A key is either fixed or one of
 * the two per-record families (`reminders.routine.<uuid>`,
 * `reminders.person.<uuid>`). Every value is validated against its own strict
 * schema; unknown keys are refused. The database CHECK on `account_settings.key`
 * repeats the key pattern (migration 0031).
 */
export const ACCOUNT_SETTING_MAX_VALUE_BYTES = 8192;
export const ACCOUNT_SETTINGS_MAX_KEYS = 2000;
export const ACCOUNT_SETTINGS_PAGE_SIZE = 500;
export const ACCOUNT_SETTINGS_MAX_CHANGES = 100;

export const ACCOUNT_SETTING_KEY_PATTERN = /^(reminders\.snoozeMinutes|reminders\.(routine|person)\.[0-9a-f-]{36}|recordedBy|asNeeded\.inStats|medications\.siblingDetection|today\.noticesLater|appearance\.(text|colors)|language)$/;

const Uuid = z.string().uuid();
const IsoDay = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);

/** The 21 colour roles of the app theme editor; values are opaque ARGB. */
export const APPEARANCE_COLOR_ROLES = [
  'primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer', 'background', 'text',
  'surface', 'surfaceVariant', 'mutedText', 'border', 'secondary', 'onSecondary', 'tertiary',
  'onTertiary', 'error', 'onError', 'taken', 'skipped', 'unrecorded', 'activePerson',
  'inactivePerson',
] as const;

const ColorMap = z.partialRecord(
  z.enum(APPEARANCE_COLOR_ROLES),
  z.number().int().min(0xff000000).max(0xffffffff),
);

export const ReminderRoutineSettingSchema = z.object({
  enabled: z.boolean(),
  followUpMinutes: z.array(z.number().int().min(1).max(720)).max(6),
}).strict();
export const ReminderPersonSettingSchema = z.object({ enabled: z.boolean() }).strict();

export const RecordedBySettingSchema = z.object({
  version: z.literal(1),
  mode: z.enum(['primaryProfile', 'custom', 'personTakingIt']),
  customName: z.string().trim().min(1).max(60).optional(),
}).strict();

export const NoticesLaterSettingSchema = z.array(z.object({
  medicationId: Uuid,
  until: IsoDay,
}).strict()).max(500);

export const AppearanceTextSettingSchema = z.object({
  fontSize: z.enum(['defaultSize', 'large', 'extraLarge']),
  highContrast: z.boolean(),
  reduceMotion: z.boolean(),
}).strict();

export const AppearanceColorsSettingSchema = z.object({ light: ColorMap, dark: ColorMap }).strict();

// Any BCP-47 shaped tag: adding a locale to the app needs no server release.
// The client clamps a tag it cannot show to the system language.
export const LanguageSettingSchema = z.union([
  z.literal('system'),
  z.string().regex(/^[a-z]{2,3}(-[A-Z]{2})?$/),
]);

const FIXED_SCHEMAS: Readonly<Record<string, z.ZodType>> = {
  'reminders.snoozeMinutes': z.number().int().min(1).max(240),
  recordedBy: RecordedBySettingSchema,
  'asNeeded.inStats': z.boolean(),
  'medications.siblingDetection': z.enum(['nameAndDosage', 'nameOnly', 'perPill']),
  'today.noticesLater': NoticesLaterSettingSchema,
  'appearance.text': AppearanceTextSettingSchema,
  'appearance.colors': AppearanceColorsSettingSchema,
  language: LanguageSettingSchema,
};

const ROUTINE_PREFIX = 'reminders.routine.';
const PERSON_PREFIX = 'reminders.person.';

export const reminderRoutineKey = (scheduleId: string): string => `${ROUTINE_PREFIX}${scheduleId}`;
export const reminderPersonKey = (profileId: string): string => `${PERSON_PREFIX}${profileId}`;

export function isKnownAccountSettingKey(key: string): boolean {
  if (!ACCOUNT_SETTING_KEY_PATTERN.test(key)) return false;
  if (key.startsWith(ROUTINE_PREFIX)) return Uuid.safeParse(key.slice(ROUTINE_PREFIX.length)).success;
  if (key.startsWith(PERSON_PREFIX)) return Uuid.safeParse(key.slice(PERSON_PREFIX.length)).success;
  return Object.hasOwn(FIXED_SCHEMAS, key);
}

/** The value schema of a known key; undefined for an unknown key. */
export function accountSettingValueSchema(key: string): z.ZodType | undefined {
  if (!isKnownAccountSettingKey(key)) return undefined;
  if (key.startsWith(ROUTINE_PREFIX)) return ReminderRoutineSettingSchema;
  if (key.startsWith(PERSON_PREFIX)) return ReminderPersonSettingSchema;
  return FIXED_SCHEMAS[key];
}

export const AccountSettingsQuerySchema = z.object({
  afterRevision: z.coerce.number().int().min(0).max(Number.MAX_SAFE_INTEGER).default(0),
}).strict();

export const AccountSettingChangeSchema = z.object({
  key: z.string().min(1).max(128),
  // null clears the key (a tombstone the other devices pull).
  value: z.unknown().refine((value) => value !== undefined, 'value is required'),
  baseRevision: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
  // Seed only: keep whatever the account already holds for this key.
  ifAbsent: z.boolean().optional(),
}).strict();

export const AccountSettingsPutSchema = z.object({
  changes: z.array(AccountSettingChangeSchema).min(1).max(ACCOUNT_SETTINGS_MAX_CHANGES),
}).strict();

export type AccountSettingChange = z.infer<typeof AccountSettingChangeSchema>;
