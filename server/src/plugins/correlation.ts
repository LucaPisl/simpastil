import fp from 'fastify-plugin';
import { randomUUID } from 'node:crypto';
import type { FastifyRequest } from 'fastify';

export const CORRELATION_HEADER = 'x-correlation-id';
export const MAX_CORRELATION_ID_LENGTH = 64;
const CORRELATION_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._~-]{0,63}$/;

declare module 'fastify' {
  interface FastifyRequest {
    correlationId: string;
  }
}

export default fp(async (fastify) => {
  fastify.decorateRequest('correlationId', '');
  fastify.addHook('onRequest', async (request, reply) => {
    const incoming = request.headers[CORRELATION_HEADER];
    const id = resolveCorrelationId(incoming);
    (request as FastifyRequest & { correlationId: string }).correlationId = id;
    reply.header(CORRELATION_HEADER, id);
  });
});

export function isValidCorrelationId(value: unknown): value is string {
  return typeof value === 'string'
    && value.length <= MAX_CORRELATION_ID_LENGTH
    && CORRELATION_ID_RE.test(value);
}

export function resolveCorrelationId(value: string | string[] | undefined): string {
  return typeof value === 'string' && isValidCorrelationId(value) ? value : randomUUID();
}

export function createCorrelationId(): string {
  return randomUUID();
}
