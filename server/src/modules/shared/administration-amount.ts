import { z } from 'zod';

// How much of a medicine one administration is. The same shape is stored on
// occurrence_events.administration_amount and on pills.amount_per_use, and the
// clients parse both with one decoder, so it is validated in one place here
// rather than once per module.
const KnownAmountSchema = z.object({
  version: z.literal(1),
  state: z.literal('known'),
  quantity: z.string().min(1).max(64).refine((value) => {
    const fraction = /^(\d+)\s*\/\s*(\d+)$/.exec(value);
    if (fraction) return BigInt(fraction[1]!) > 0n && BigInt(fraction[2]!) > 0n;
    const decimal = /^(\d+)(?:[.,](\d+))?$/.exec(value);
    if (!decimal) return false;
    const digits = decimal[2] ?? '';
    return BigInt(`${decimal[1]}${digits}`) > 0n;
  }, 'quantity must be a positive decimal or fraction'),
  unit: z.string().min(1).max(80).refine((value) => value === value.trim(), 'unit must be trimmed'),
}).strict();

export const AdministrationAmountSchema = z.discriminatedUnion('state', [
  z.object({ version: z.literal(1), state: z.literal('unknown') }).strict(),
  KnownAmountSchema,
]);

export type AdministrationAmount = z.infer<typeof AdministrationAmountSchema>;
