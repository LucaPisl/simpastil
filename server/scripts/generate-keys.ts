/**
 * Generates an RSA-2048 keypair and prints the values ready to paste into .env.
 *
 * Usage: npx tsx scripts/generate-keys.ts
 */
import { generateKeyPairSync } from 'node:crypto';

const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});

// Shell/dotenv cannot contain literal newlines inside quoted strings.
// Replace every actual newline with the two-character sequence \n so the
// value fits on one line and can be pasted directly into .env.
const escape = (pem: string) => pem.replace(/\n/g, '\\n');

console.log('Add these two lines to your .env file:\n');
console.log(`JWT_PRIVATE_KEY="${escape(privateKey)}"`);
console.log(`JWT_PUBLIC_KEY="${escape(publicKey)}"`);
console.log('\n⚠  Keep JWT_PRIVATE_KEY secret — it signs all access tokens.');
console.log('   JWT_PUBLIC_KEY can be shared with verification services.');
