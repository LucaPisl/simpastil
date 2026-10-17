import type { Sql } from 'postgres';

export interface ClaimedOutboxMessage {
  id: string;
  messageType: string;
  recipient: string;
  encryptedPayload: string;
  attemptCount: number;
  correlationId: string | null;
  expiresAt: Date;
  /** Fences completion updates from an expired claim without adding a schema column. */
  leaseExpiresAt: Date;
}

export interface ExpiredOutboxMessage {
  attemptCount: number;
  correlationId: string | null;
}

export interface ClaimedOutboxBatch {
  messages: ClaimedOutboxMessage[];
  expired: ExpiredOutboxMessage[];
}

export interface OutboxRepository {
  claimBatch(limit: number, leaseMs: number): Promise<ClaimedOutboxBatch>;
  markSent(message: ClaimedOutboxMessage): Promise<boolean>;
  recordFailure(
    message: ClaimedOutboxMessage,
    category: string,
    retryAt?: Date,
  ): Promise<boolean>;
}

type DbTimestamp = Date | string;

interface ClaimedRow {
  id: string;
  messageType: string;
  recipient: string;
  encryptedPayload: string;
  attemptCount: number;
  correlationId: string | null;
  expiresAt: DbTimestamp;
  leaseExpiresAt: DbTimestamp;
}

interface ExpiredRow {
  attemptCount: number;
  correlationId: string | null;
}

interface IdRow {
  id: string;
}

function asDate(value: DbTimestamp): Date {
  return value instanceof Date ? value : new Date(value);
}

/**
 * Raw SQL is intentional: the worker role gets a queue-only connection and
 * never imports the API's Drizzle schema or application database factory.
 */
export class PostgresOutboxRepository implements OutboxRepository {
  constructor(private readonly sql: Sql) {}

  async claimBatch(limit: number, leaseMs: number): Promise<ClaimedOutboxBatch> {
    return this.sql.begin(async (transaction) => {
      const expired = await transaction.unsafe<ExpiredRow[]>(`
        UPDATE public.outbox_messages
        SET state = 'failedPermanent',
            encrypted_delivery_payload = NULL,
            safe_error_category = 'expired',
            lease_expires_at = NULL,
            updated_at = clock_timestamp()
        WHERE expires_at <= clock_timestamp()
          AND (
            state IN ('queued', 'retrying')
            OR (state = 'sending' AND lease_expires_at <= clock_timestamp())
          )
        RETURNING attempt_count AS "attemptCount", correlation_id AS "correlationId"
      `);

      const rows = await transaction.unsafe<ClaimedRow[]>(`
        WITH candidates AS (
          SELECT id
          FROM public.outbox_messages
          WHERE expires_at > clock_timestamp()
            AND (
              (state IN ('queued', 'retrying') AND next_attempt_at <= clock_timestamp())
              OR (state = 'sending' AND lease_expires_at <= clock_timestamp())
            )
          ORDER BY next_attempt_at, created_at, id
          LIMIT $1
          FOR UPDATE SKIP LOCKED
        )
        UPDATE public.outbox_messages AS message
        SET state = 'sending',
            attempt_count = message.attempt_count + 1,
            lease_expires_at = GREATEST(
              date_trunc('milliseconds', clock_timestamp()),
              COALESCE(message.lease_expires_at + interval '1 millisecond', '-infinity'::timestamptz)
            ) + ($2::integer * interval '1 millisecond'),
            updated_at = clock_timestamp()
        FROM candidates
        WHERE message.id = candidates.id
        RETURNING message.id,
                  message.message_type AS "messageType",
                  message.recipient_ref AS recipient,
                  message.encrypted_delivery_payload AS "encryptedPayload",
                  message.attempt_count AS "attemptCount",
                  message.correlation_id AS "correlationId",
                  message.expires_at AS "expiresAt",
                  message.lease_expires_at AS "leaseExpiresAt"
      `, [limit, leaseMs]);

      return {
        expired: expired.map((row) => ({
          attemptCount: row.attemptCount,
          correlationId: row.correlationId,
        })),
        messages: rows.map((row) => ({
          ...row,
          expiresAt: asDate(row.expiresAt),
          leaseExpiresAt: asDate(row.leaseExpiresAt),
        })),
      };
    });
  }

  async markSent(message: ClaimedOutboxMessage): Promise<boolean> {
    const rows = await this.sql.unsafe<IdRow[]>(`
      UPDATE public.outbox_messages
      SET state = 'sent',
          encrypted_delivery_payload = NULL,
          safe_error_category = NULL,
          lease_expires_at = NULL,
          sent_at = clock_timestamp(),
          updated_at = clock_timestamp()
      WHERE id = $1
        AND state = 'sending'
        AND lease_expires_at = $2::timestamptz
      RETURNING id
    `, [message.id, message.leaseExpiresAt.toISOString()]);
    return rows.length === 1;
  }

  async recordFailure(
    message: ClaimedOutboxMessage,
    category: string,
    retryAt?: Date,
  ): Promise<boolean> {
    const state = retryAt ? 'retrying' : 'failedPermanent';
    const rows = await this.sql.unsafe<IdRow[]>(`
      UPDATE public.outbox_messages
      SET state = $3,
          encrypted_delivery_payload = CASE WHEN $3 = 'failedPermanent'
            THEN NULL ELSE encrypted_delivery_payload END,
          safe_error_category = $4,
          next_attempt_at = CASE WHEN $3 = 'retrying'
            THEN $5::timestamptz ELSE next_attempt_at END,
          lease_expires_at = NULL,
          updated_at = clock_timestamp()
      WHERE id = $1
        AND state = 'sending'
        AND lease_expires_at = $2::timestamptz
      RETURNING id
    `, [
      message.id,
      message.leaseExpiresAt.toISOString(),
      state,
      category,
      retryAt?.toISOString() ?? null,
    ]);
    return rows.length === 1;
  }
}
