import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 12;
const TAG_LENGTH = 16;

export interface DeliveryPayloadSealer {
  seal(payload: string): string;
}

export interface DeliveryPayloadOpener {
  open(ciphertext: string): string;
}

export class DeliveryPayloadCryptoError extends Error {
  constructor(message = 'Delivery payload key must be exactly 64 hexadecimal characters') {
    super(message);
    this.name = 'DeliveryPayloadCryptoError';
  }
}

function keyFromHex(hex: string): Buffer {
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) throw new DeliveryPayloadCryptoError();
  return Buffer.from(hex, 'hex');
}

export function createDeliveryPayloadSealer(hex: string): DeliveryPayloadSealer {
  const key = keyFromHex(hex);
  return Object.freeze({
    seal(payload: string): string {
      const iv = randomBytes(IV_LENGTH);
      const cipher = createCipheriv(ALGORITHM, key, iv, { authTagLength: TAG_LENGTH });
      const ciphertext = Buffer.concat([cipher.update(payload, 'utf8'), cipher.final()]);
      return `${iv.toString('base64')}:${ciphertext.toString('base64')}:${cipher.getAuthTag().toString('base64')}`;
    },
  });
}

export function createDeliveryPayloadOpener(hex: string): DeliveryPayloadOpener {
  const key = keyFromHex(hex);
  return Object.freeze({
    open(ciphertext: string): string {
      const parts = ciphertext.split(':');
      if (parts.length !== 3) throw new DeliveryPayloadCryptoError('Invalid delivery payload format');
      const iv = Buffer.from(parts[0]!, 'base64');
      const encrypted = Buffer.from(parts[1]!, 'base64');
      const tag = Buffer.from(parts[2]!, 'base64');
      const decipher = createDecipheriv(ALGORITHM, key, iv, { authTagLength: TAG_LENGTH });
      decipher.setAuthTag(tag);
      return decipher.update(encrypted) + decipher.final('utf8');
    },
  });
}
