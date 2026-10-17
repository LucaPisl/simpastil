import { describe, expect, it, vi } from 'vitest';
import type { DeliveryPayloadOpener } from '../../lib/delivery-payload-crypto.js';
import type { ClaimedOutboxBatch, ClaimedOutboxMessage, OutboxRepository } from '../../outbox/outbox-repository.js';
import { OutboxWorker, type SafeWorkerLog } from '../../outbox/outbox-worker.js';
import { SmtpDeliveryError, type OutboxDelivery } from '../../outbox/smtp-delivery.js';

const NOW = Date.parse('2026-09-26T10:00:00.000Z');
const TOKEN = 'sensitive-recovery-token-value-long-enough-1234567890';

function message(overrides: Partial<ClaimedOutboxMessage> = {}): ClaimedOutboxMessage {
  return {
    id: 'outbox-123',
    messageType: 'password-reset',
    recipient: 'person@example.invalid',
    encryptedPayload: JSON.stringify({ token: TOKEN }),
    attemptCount: 1,
    correlationId: 'corr-123',
    expiresAt: new Date(NOW + 60_000),
    leaseExpiresAt: new Date(NOW + 30_000),
    ...overrides,
  };
}

function batch(...messages: ClaimedOutboxMessage[]): ClaimedOutboxBatch {
  return { messages, expired: [] };
}

function harness(options: {
  item?: ClaimedOutboxMessage;
  payload?: string;
  open?: (value: string) => string;
  deliver?: (value: Parameters<OutboxDelivery['deliver']>[0]) => Promise<void>;
  markSent?: () => Promise<boolean>;
  recordFailure?: (category: string, retryAt?: Date) => Promise<boolean>;
  claimBatch?: () => Promise<ClaimedOutboxBatch>;
  random?: () => number;
} = {}) {
  const item = options.item ?? message();
  const logs: SafeWorkerLog[] = [];
  let claimedInitialBatch = false;
  const claimBatch = options.claimBatch ?? (async () => {
    if (claimedInitialBatch) return batch();
    claimedInitialBatch = true;
    return batch(item);
  });
  const repository = {
    claimBatch: vi.fn(claimBatch),
    markSent: vi.fn(options.markSent ?? (async () => true)),
    recordFailure: vi.fn(async (_claimed: ClaimedOutboxMessage, category: string, retryAt?: Date) =>
      options.recordFailure ? options.recordFailure(category, retryAt) : true),
  } satisfies OutboxRepository;
  const delivery: OutboxDelivery = {
    deliver: vi.fn(options.deliver ?? (async () => undefined)),
    close: vi.fn(),
  };
  const payloadOpener: DeliveryPayloadOpener = {
    open: vi.fn(options.open ?? ((value) => options.payload ?? value)),
  };
  const worker = new OutboxWorker({
    repository,
    payloadOpener,
    delivery,
    publicAppUrl: 'https://app.example.invalid/path',
    now: () => NOW,
    random: options.random ?? (() => 0.5),
    logger: (record) => logs.push(record),
    pollIntervalMs: 60_000,
  });
  return { item, logs, repository, delivery, payloadOpener, worker };
}

async function processOne(
  worker: OutboxWorker,
  finished: () => boolean,
): Promise<void> {
  const running = worker.run();
  await vi.waitFor(() => expect(finished()).toBe(true));
  expect(await worker.drain(NOW + 10_000)).toBe(true);
  await running;
}

describe('OutboxWorker', () => {
  it('delivers a reset link built from the decrypted token, then clears the claimed row', async () => {
    const h = harness();
    await processOne(h.worker, () => h.repository.markSent.mock.calls.length === 1);

    expect(h.delivery.deliver).toHaveBeenCalledWith({
      id: h.item.id,
      kind: 'password-reset',
      recipient: h.item.recipient,
      link: `https://app.example.invalid/#/reset-password?token=${encodeURIComponent(TOKEN)}`,
    });
    expect(h.repository.markSent).toHaveBeenCalledWith(h.item);
    expect(h.logs).toContainEqual(expect.objectContaining({ event: 'outbox.sent', correlationId: 'corr-123' }));
  });

  it('routes invitation records to the invitation link and rejects unknown message types permanently', async () => {
    const invitation = harness({ item: message({ messageType: 'invite' }) });
    await processOne(invitation.worker, () => invitation.repository.markSent.mock.calls.length === 1);
    expect(invitation.delivery.deliver).toHaveBeenCalledWith(expect.objectContaining({
      kind: 'invite',
      link: `https://app.example.invalid/#/invite?token=${encodeURIComponent(TOKEN)}`,
    }));

    const unsupported = harness({ item: message({ messageType: 'welcome' }) });
    await processOne(unsupported.worker, () => unsupported.repository.recordFailure.mock.calls.length === 1);
    expect(unsupported.delivery.deliver).not.toHaveBeenCalled();
    expect(unsupported.repository.recordFailure).toHaveBeenCalledWith(
      unsupported.item,
      'unsupported_message_type',
      undefined,
    );
    expect(unsupported.logs).toContainEqual(expect.objectContaining({
      event: 'outbox.failed_permanent',
      category: 'unsupported_message_type',
    }));
  });

  it('erases invalid encrypted payloads permanently without exposing payload or recipient in logs', async () => {
    const h = harness({
      item: message({ encryptedPayload: 'raw-ciphertext-marker' }),
      open: () => { throw new Error(`decrypt failed for ${TOKEN}`); },
    });
    await processOne(h.worker, () => h.repository.recordFailure.mock.calls.length === 1);

    expect(h.delivery.deliver).not.toHaveBeenCalled();
    expect(h.repository.recordFailure).toHaveBeenCalledWith(h.item, 'invalid_payload', undefined);
    const serializedLogs = JSON.stringify(h.logs);
    expect(serializedLogs).not.toContain(TOKEN);
    expect(serializedLogs).not.toContain(h.item.recipient);
    expect(serializedLogs).not.toContain('raw-ciphertext-marker');
  });

  it('schedules transient SMTP failures with bounded injected jitter', async () => {
    let scheduled: Date | undefined;
    const h = harness({
      item: message({ attemptCount: 2 }),
      deliver: async () => { throw new SmtpDeliveryError('smtp_transient'); },
      recordFailure: async (_category, retryAt) => { scheduled = retryAt; return true; },
      random: () => 0.5,
    });
    await processOne(h.worker, () => h.repository.recordFailure.mock.calls.length === 1);

    expect(h.repository.recordFailure).toHaveBeenCalledWith(h.item, 'smtp_transient', new Date(NOW + 5_000));
    expect(scheduled?.getTime()).toBe(NOW + 5_000);
    expect(h.logs).toContainEqual(expect.objectContaining({ event: 'outbox.retry_scheduled', category: 'smtp_transient' }));
  });

  it('does not retry permanent recipient rejection or exhausted attempts', async () => {
    const permanent = harness({
      deliver: async () => { throw new SmtpDeliveryError('smtp_recipient_rejected'); },
    });
    await processOne(permanent.worker, () => permanent.repository.recordFailure.mock.calls.length === 1);
    expect(permanent.repository.recordFailure).toHaveBeenCalledWith(permanent.item, 'smtp_recipient_rejected', undefined);

    const exhausted = harness({
      item: message({ attemptCount: 8 }),
      deliver: async () => { throw new SmtpDeliveryError('smtp_transient'); },
    });
    await processOne(exhausted.worker, () => exhausted.repository.recordFailure.mock.calls.length === 1);
    expect(exhausted.repository.recordFailure).toHaveBeenCalledWith(exhausted.item, 'smtp_transient', undefined);
  });

  it('records lease loss instead of claiming a delivery was finalized', async () => {
    const h = harness({ markSent: async () => false });
    await processOne(h.worker, () => h.repository.markSent.mock.calls.length === 1);
    expect(h.logs).toContainEqual(expect.objectContaining({
      event: 'outbox.finalization_failed',
      category: 'lease_lost',
    }));
  });
});
