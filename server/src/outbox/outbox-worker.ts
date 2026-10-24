import type { DeliveryPayloadOpener } from '../lib/delivery-payload-crypto.js';
import { buildRecoveryLink } from '../lib/recovery-links.js';
import {
  SmtpDeliveryError,
  type OutboxDelivery,
  type RecoveryMessageKind,
} from './smtp-delivery.js';
import type { ClaimedOutboxMessage, OutboxRepository } from './outbox-repository.js';
import { logProcessEvent } from '../lib/process-log.js';
import { describeFailure, sanitizeCause, type SafeCause } from '../lib/failure-cause.js';

const MAX_ATTEMPTS = 8;
const BASE_RETRY_MS = 5_000;
const MAX_RETRY_MS = 30 * 60 * 1_000;

type SafeCategory =
  | 'expired'
  | 'invalid_payload'
  | 'unsupported_message_type'
  | 'smtp_recipient_rejected'
  | 'smtp_transient'
  | 'delivery_failed'
  | 'database_failure'
  | 'lease_lost';

type WorkerEvent =
  | 'outbox.expired'
  | 'outbox.sent'
  | 'outbox.retry_scheduled'
  | 'outbox.failed_permanent'
  | 'outbox.finalization_failed';

class InvalidDeliveryPayload extends Error {}

export interface SafeWorkerLog extends SafeCause {
  event: WorkerEvent;
  category?: SafeCategory;
  attempt?: number;
  correlationId?: string;
}

export interface OutboxWorkerOptions {
  repository: OutboxRepository;
  payloadOpener: DeliveryPayloadOpener;
  delivery: OutboxDelivery;
  publicAppUrl: string;
  batchSize?: number;
  leaseMs?: number;
  pollIntervalMs?: number;
  now?: () => number;
  random?: () => number;
  logger?: (record: SafeWorkerLog) => void;
}

function parseToken(opener: DeliveryPayloadOpener, ciphertext: string): string {
  let opened: string;
  try {
    opened = opener.open(ciphertext);
  } catch {
    throw new InvalidDeliveryPayload();
  }
  let value: unknown;
  try {
    value = JSON.parse(opened);
  } catch {
    throw new InvalidDeliveryPayload();
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new InvalidDeliveryPayload();
  }
  const record = value as Record<string, unknown>;
  if (Object.keys(record).length !== 1 || typeof record['token'] !== 'string') {
    throw new InvalidDeliveryPayload();
  }
  const token = record['token'];
  if (token.length < 32 || token.length > 512) throw new InvalidDeliveryPayload();
  return token;
}

/** The notice to the old address carries no token: its payload is an empty object. */
function parseEmptyPayload(opener: DeliveryPayloadOpener, ciphertext: string): void {
  let value: unknown;
  try {
    value = JSON.parse(opener.open(ciphertext));
  } catch {
    throw new InvalidDeliveryPayload();
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)
      || Object.keys(value).length !== 0) {
    throw new InvalidDeliveryPayload();
  }
}

function messageKind(messageType: string): RecoveryMessageKind | undefined {
  if (messageType === 'password-reset' || messageType === 'invite'
      || messageType === 'email-change-confirm' || messageType === 'email-change-notice') {
    return messageType;
  }
  return undefined;
}

function safeCorrelationId(value: string | null): string | undefined {
  return value && /^[A-Za-z0-9._:-]{1,80}$/.test(value) ? value : undefined;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export class OutboxWorker {
  private readonly repository: OutboxRepository;
  private readonly payloadOpener: DeliveryPayloadOpener;
  private readonly delivery: OutboxDelivery;
  private readonly publicAppUrl: string;
  private readonly batchSize: number;
  private readonly leaseMs: number;
  private readonly pollIntervalMs: number;
  private readonly now: () => number;
  private readonly random: () => number;
  private readonly logger: (record: SafeWorkerLog) => void;
  private readonly inFlight = new Set<Promise<void>>();
  private pollInFlight: Promise<number> | undefined;
  private stopRequested = false;
  private wakePoll: (() => void) | undefined;

  constructor(options: OutboxWorkerOptions) {
    this.repository = options.repository;
    this.payloadOpener = options.payloadOpener;
    this.delivery = options.delivery;
    this.publicAppUrl = options.publicAppUrl;
    this.batchSize = options.batchSize ?? 10;
    this.leaseMs = options.leaseMs ?? 60_000;
    this.pollIntervalMs = options.pollIntervalMs ?? 2_000;
    this.now = options.now ?? Date.now;
    this.random = options.random ?? Math.random;
    this.logger = options.logger ?? ((record) => {
      const { event, ...fields } = record;
      logProcessEvent('info', event, fields);
    });
  }

  async run(): Promise<void> {
    while (!this.stopRequested) {
      const poll = this.pollOnce();
      this.pollInFlight = poll;
      const claimed = await poll;
      if (this.pollInFlight === poll) this.pollInFlight = undefined;
      if (this.stopRequested) break;
      if (claimed === 0) await this.waitForPoll();
    }
  }

  /** Stops future claims and waits for active deliveries until the deadline. */
  async drain(deadline: number | Date): Promise<boolean> {
    this.stopRequested = true;
    this.wakePoll?.();
    const deadlineMs = deadline instanceof Date ? deadline.getTime() : deadline;
    while (this.pollInFlight !== undefined || this.inFlight.size > 0) {
      const remaining = deadlineMs - this.now();
      if (remaining <= 0) return false;
      await Promise.race([
        ...(this.pollInFlight ? [this.pollInFlight] : []),
        ...this.inFlight,
        sleep(remaining),
      ]);
    }
    return true;
  }

  private async pollOnce(): Promise<number> {
    if (this.stopRequested) return 0;
    let batch;
    try {
      batch = await this.repository.claimBatch(this.batchSize, this.leaseMs);
    } catch (error) {
      this.log({ event: 'outbox.finalization_failed', category: 'database_failure', ...describeFailure(error) });
      return 0;
    }

    for (const expired of batch.expired) {
      this.log({
        event: 'outbox.expired',
        category: 'expired',
        attempt: expired.attemptCount,
        correlationId: expired.correlationId,
      });
    }

    const active = batch.messages.map((message) => {
      const task = this.deliverOne(message);
      this.inFlight.add(task);
      void task.then(
        () => this.inFlight.delete(task),
        () => this.inFlight.delete(task),
      );
      return task;
    });
    await Promise.all(active);
    return active.length;
  }

  private async deliverOne(message: ClaimedOutboxMessage): Promise<void> {
    const kind = messageKind(message.messageType);
    if (!kind) {
      await this.fail(message, 'unsupported_message_type', true);
      return;
    }
    if (message.expiresAt.getTime() <= this.now()) {
      await this.fail(message, 'expired', true);
      return;
    }

    try {
      let link = '';
      if (kind === 'email-change-notice') {
        parseEmptyPayload(this.payloadOpener, message.encryptedPayload);
      } else {
        const token = parseToken(this.payloadOpener, message.encryptedPayload);
        const linkKind = kind === 'password-reset'
          ? 'reset-password'
          : kind === 'email-change-confirm' ? 'confirm-email' : 'invite';
        link = buildRecoveryLink(this.publicAppUrl, linkKind, token);
      }
      await this.delivery.deliver({
        id: message.id,
        kind,
        recipient: message.recipient,
        link,
      });
    } catch (error) {
      const category: SafeCategory = error instanceof InvalidDeliveryPayload || error instanceof SyntaxError
        ? 'invalid_payload'
        : error instanceof SmtpDeliveryError
        ? error.safeCategory
        : 'delivery_failed';
      const permanent = category === 'invalid_payload'
        || category === 'smtp_recipient_rejected';
      // A malformed payload is explained by its category alone; the others
      // also say what the mail server or the network did.
      await this.fail(message, category, permanent, category === 'invalid_payload' ? undefined : error);
      return;
    }

    try {
      const updated = await this.repository.markSent(message);
      this.log({
        event: updated ? 'outbox.sent' : 'outbox.finalization_failed',
        ...(updated ? {} : { category: 'lease_lost' as const }),
        attempt: message.attemptCount,
        correlationId: message.correlationId,
      });
    } catch (error) {
      // SMTP may have accepted the stable Message-ID before a DB failure. The
      // lease will expire and delivery is at-least-once, never falsely "sent".
      this.log({
        event: 'outbox.finalization_failed',
        category: 'database_failure',
        attempt: message.attemptCount,
        correlationId: message.correlationId,
        ...describeFailure(error),
      });
    }
  }

  private async fail(
    message: ClaimedOutboxMessage,
    category: SafeCategory,
    permanent: boolean,
    failure?: unknown,
  ): Promise<void> {
    const terminal = permanent || message.attemptCount >= MAX_ATTEMPTS;
    const retryAt = terminal
      ? undefined
      : new Date(this.now() + this.retryDelay(message.attemptCount));
    try {
      const updated = await this.repository.recordFailure(message, category, retryAt);
      this.log({
        event: terminal ? 'outbox.failed_permanent' : 'outbox.retry_scheduled',
        category: updated ? category : 'lease_lost',
        attempt: message.attemptCount,
        correlationId: message.correlationId,
        ...(failure === undefined ? {} : describeFailure(failure)),
      });
    } catch (error) {
      this.log({
        event: 'outbox.finalization_failed',
        category: 'database_failure',
        attempt: message.attemptCount,
        correlationId: message.correlationId,
        ...describeFailure(error),
      });
    }
  }

  private retryDelay(attempt: number): number {
    const ceiling = Math.min(MAX_RETRY_MS, BASE_RETRY_MS * (2 ** Math.max(0, attempt - 1)));
    const randomValue = this.random();
    const sample = Number.isFinite(randomValue)
      ? Math.min(0.999_999_999, Math.max(0, randomValue))
      : 0;
    return Math.floor(sample * ceiling);
  }

  private async waitForPoll(): Promise<void> {
    if (this.stopRequested) return;
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        this.wakePoll = undefined;
        resolve();
      }, this.pollIntervalMs);
      this.wakePoll = () => {
        clearTimeout(timer);
        this.wakePoll = undefined;
        resolve();
      };
    });
  }

  private log(record: Omit<SafeWorkerLog, 'correlationId'> & { correlationId?: string | null }): void {
    try {
      const correlationId = safeCorrelationId(record.correlationId ?? null);
      this.logger({
        event: record.event,
        ...(record.category ? { category: record.category } : {}),
        ...(record.attempt === undefined ? {} : { attempt: record.attempt }),
        ...(correlationId ? { correlationId } : {}),
        // Only allowlisted, pattern-checked cause fields ever reach the log.
        ...sanitizeCause(record),
      });
    } catch {
      // A diagnostics sink must never interrupt token delivery or cleanup.
    }
  }
}
