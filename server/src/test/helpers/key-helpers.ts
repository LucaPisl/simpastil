import { generateKeyPairSync } from 'node:crypto';

export interface TestKeyPair {
  privateKey: string;
  publicKey: string;
}

/** Generates an ephemeral RS256 key pair for use in tests. */
export function generateTestKeyPair(): TestKeyPair {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding:  { type: 'spki',   format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8',  format: 'pem' },
  });
  return { privateKey, publicKey };
}
