import { z } from 'zod';

export const DEFAULT_LIMIT = 50;
export const MAX_LIMIT = 1000;
export const MAX_OFFSET = 1_000_000;

type PaginationOptions = {
  maxLimit?: number;
  maxOffset?: number;
  defaultLimit?: number;
};

function boundedInteger(minimum: number, maximum: number) {
  const input = z.union([
    z.string().regex(/^(0|[1-9]\d*)$/, 'must be a decimal integer').transform(Number),
    z.number().refine(Number.isSafeInteger, 'must be a safe integer'),
  ]);
  return input.pipe(z.number().int().min(minimum).max(maximum));
}

export function createPaginationSchema(options: PaginationOptions = {}) {
  const maxLimit = options.maxLimit ?? MAX_LIMIT;
  const maxOffset = options.maxOffset ?? MAX_OFFSET;
  return z.object({
    limit: boundedInteger(1, maxLimit).optional(),
    offset: boundedInteger(0, maxOffset).optional(),
  });
}

export const PaginationSchema = createPaginationSchema();
export const AdminPaginationSchema = createPaginationSchema({ maxLimit: 200 });

export function parsePagination(input: unknown, options: PaginationOptions = {}): { limit: number; offset: number } {
  const result = createPaginationSchema(options).parse(input);
  const defaultLimit = options.defaultLimit ?? DEFAULT_LIMIT;
  const maxLimit = options.maxLimit ?? MAX_LIMIT;
  if (!Number.isSafeInteger(defaultLimit) || defaultLimit < 1 || defaultLimit > maxLimit) {
    throw new Error('defaultLimit must be within the configured limit bounds');
  }
  return { limit: result.limit ?? defaultLimit, offset: result.offset ?? 0 };
}

export type Pagination = z.infer<typeof PaginationSchema>;
