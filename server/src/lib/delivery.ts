export type DeliveryMessageKind = 'password-reset' | 'invite';

export interface DeliveryMessage {
  kind: DeliveryMessageKind;
  recipient: string;
  payload: string;
}

export interface DeliveryEnvelope {
  kind: DeliveryMessageKind;
  recipient: string;
  ciphertext: string;
}

export interface DeliveryEnvelopeSink {
  enqueue(envelope: DeliveryEnvelope): Promise<void>;
}

export interface DeliverySubmitter {
  submit(message: DeliveryMessage): Promise<void>;
}

export function createDeliverySubmitter(
  seal: (payload: string) => string,
  sink: DeliveryEnvelopeSink,
): DeliverySubmitter {
  return Object.freeze({
    async submit(message: DeliveryMessage): Promise<void> {
      await sink.enqueue({
        kind: message.kind,
        recipient: message.recipient,
        ciphertext: seal(message.payload),
      });
    },
  });
}

export function createUnavailableDeliverySink(reason: string): DeliveryEnvelopeSink {
  return Object.freeze({
    async enqueue(): Promise<void> {
      throw new Error(reason);
    },
  });
}
