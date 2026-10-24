import { z } from 'zod';

// The silhouette a person picked for a medication, so it can be told apart
// without relying on its colour. Stored on pills.shape and carried on the
// stable pill payload. The names are the wire contract: clients draw their own
// silhouettes from them, so a value is only ever added together with a
// capability bump, never repurposed.
export const MEDICATION_SHAPES = [
  'round',
  'caplet',
  'oval',
  'softgel',
  'capsule',
  'triangle',
  'square',
  'diamond',
  'drop',
] as const;

export type MedicationShape = (typeof MEDICATION_SHAPES)[number];

// Null and absent both mean "no shape chosen yet": the client then draws the
// shape it derives from the medication's form.
export const MedicationShapeSchema = z.enum(MEDICATION_SHAPES);
