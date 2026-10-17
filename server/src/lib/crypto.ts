import { createHash, createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

export const sha256Hex = (input: string): string =>
  createHash('sha256').update(input).digest('hex');

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 12;
const TAG_LENGTH = 16;
export class EncryptionNotConfiguredError extends Error {
  constructor() {
    super('TOTP_ENC_KEY must be a 64-character hex string (32 bytes)');
    this.name = 'EncryptionNotConfiguredError';
  }
}

export interface EncryptionCapabilities {
  encrypt(plaintext: string): string;
  decrypt(ciphertext: string): string;
  isEncrypted(value: string): boolean;
}

function keyFromHex(hex: string): Buffer {
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) {
    throw new EncryptionNotConfiguredError();
  }
  return Buffer.from(hex, 'hex');
}

export function isEncryptedFormat(value: string): boolean {
  return value.includes(':') && value.split(':').length === 3;
}

export function createEncryptionCapabilities(hex: string): EncryptionCapabilities {
  const key = keyFromHex(hex);
  return Object.freeze({
    encrypt(plaintext: string): string {
      const iv = randomBytes(IV_LENGTH);
      const cipher = createCipheriv(ALGORITHM, key, iv, { authTagLength: TAG_LENGTH });
      const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
      const tag = cipher.getAuthTag();
      return `${iv.toString('base64')}:${encrypted.toString('base64')}:${tag.toString('base64')}`;
    },
    decrypt(ciphertext: string): string {
      const parts = ciphertext.split(':');
      if (parts.length !== 3) throw new Error('Invalid encrypted value format');
      const iv = Buffer.from(parts[0]!, 'base64');
      const encrypted = Buffer.from(parts[1]!, 'base64');
      const tag = Buffer.from(parts[2]!, 'base64');
      const decipher = createDecipheriv(ALGORITHM, key, iv, { authTagLength: TAG_LENGTH });
      decipher.setAuthTag(tag);
      return decipher.update(encrypted) + decipher.final('utf8');
    },
    isEncrypted: isEncryptedFormat,
  });
}
