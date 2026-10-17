import { createHmac, timingSafeEqual } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { z } from 'zod';
import { ApiError } from '../shared/api-error.js';
import { ErrorCode } from '../shared/errors.js';

export const ComponentNameSchema = z.enum(['account', 'stable', 'medicationBridge', 'medication']);
export type ComponentName = z.infer<typeof ComponentNameSchema>;

const MAX_SIGNED_64 = 9_223_372_036_854_775_807n;
const NonNegativeSequenceSchema = z.string().refine(
  (value) => /^(0|[1-9]\d{0,18})$/.test(value) && BigInt(value) <= MAX_SIGNED_64,
  'sequence must be a canonical non-negative signed-64 decimal string',
);
const MAX_PAGE_SIZE = 200;
const DEFAULT_PAGE_SIZE = 100;
const CURSOR_TTL_SECONDS = 90 * 24 * 60 * 60;

const ComponentCursorClaimsSchema = z.object({
  version: z.literal(1),
  component: ComponentNameSchema,
  contractVersion: z.union([z.literal(1), z.literal(2), z.literal(3), z.literal(4), z.literal(5)]),
  afterSequence: NonNegativeSequenceSchema,
  throughSequence: NonNegativeSequenceSchema,
  pageSize: z.number().int().min(1).max(MAX_PAGE_SIZE),
  tenantBinding: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  expiresAt: z.number().int().positive().safe(),
}).strict().superRefine((claims, ctx) => {
  if (BigInt(claims.afterSequence) > BigInt(claims.throughSequence)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'cursor sequence range is invalid', path: ['afterSequence'] });
  }
  if (!supportsContractVersion(claims.component, claims.contractVersion)) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'cursor contract does not match component', path: ['contractVersion'] });
  }
});

export type ComponentCursorClaims = z.infer<typeof ComponentCursorClaimsSchema>;

export interface NewComponentCursor {
  component: ComponentName;
  contractVersion: 1 | 2 | 3 | 4 | 5;
  afterSequence: string;
  throughSequence: string;
  pageSize: number;
}

export function supportsContractVersion(component: ComponentName, version: number): version is 1 | 2 | 3 | 4 | 5 {
  return component === 'medicationBridge'
    ? version === 1 || version === 2 || version === 3 || version === 4 || version === 5
    : version === 2;
}

function invalidCursor(): ApiError {
  return new ApiError(400, ErrorCode.VALIDATION_ERROR, 'Sync cursor is invalid or expired', { retryable: false });
}

export class ComponentCursorCodec {
  private readonly key: Buffer;

  constructor(secret: string) {
    if (!secret || secret.length < 32) throw new Error('sync cursor signing key is unavailable');
    this.key = createHmac('sha256', secret).update('simpastil/component-cursor/v1').digest();
  }

  encode(input: NewComponentCursor, userId: string, now = Date.now()): string {
    const claims = ComponentCursorClaimsSchema.parse({
      version: 1,
      ...input,
      tenantBinding: this.tenantBinding(userId),
      expiresAt: Math.floor(now / 1000) + CURSOR_TTL_SECONDS,
    });
    const payload = Buffer.from(JSON.stringify(claims), 'utf8').toString('base64url');
    const signature = createHmac('sha256', this.key).update(payload).digest('base64url');
    return `${payload}.${signature}`;
  }

  decode(token: string, userId: string, now = Date.now()): ComponentCursorClaims {
    if (token.length > 4096) throw invalidCursor();
    const parts = token.split('.');
    if (parts.length !== 2 || !parts[0] || !parts[1]) throw invalidCursor();
    const [payload, encodedSignature] = parts as [string, string];
    let actualSignature: Buffer;
    let parsed: unknown;
    try {
      actualSignature = Buffer.from(encodedSignature, 'base64url');
      parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as unknown;
    } catch {
      throw invalidCursor();
    }
    const expectedSignature = createHmac('sha256', this.key).update(payload).digest();
    if (actualSignature.length !== expectedSignature.length || !timingSafeEqual(actualSignature, expectedSignature)) {
      throw invalidCursor();
    }

    let claims: ComponentCursorClaims;
    try {
      claims = ComponentCursorClaimsSchema.parse(parsed);
    } catch {
      throw invalidCursor();
    }
    if (claims.expiresAt <= Math.floor(now / 1000)
        || !this.safeEqual(claims.tenantBinding, this.tenantBinding(userId))) {
      throw invalidCursor();
    }
    return claims;
  }

  private tenantBinding(userId: string): string {
    return createHmac('sha256', this.key).update(`tenant:${userId}`).digest('base64url');
  }

  private safeEqual(left: string, right: string): boolean {
    const leftBytes = Buffer.from(left, 'utf8');
    const rightBytes = Buffer.from(right, 'utf8');
    return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
  }
}

export const componentCursorLimits = {
  defaultPageSize: DEFAULT_PAGE_SIZE,
  maxPageSize: MAX_PAGE_SIZE,
};
