export interface RsaKeyPair {
  privateKey: string;
  publicKey: string;
}

/**
 * Loads RSA PEM key material from an explicitly supplied environment map.
 * Requiring the map keeps configuration ownership at the runtime boundary and
 * makes this function unit-testable without dynamic imports or process.env
 * mutation.
 *
 * Env vars may store newlines as the two-character sequence \n (common in
 * .env files and CI secret stores). Both forms are accepted.
 *
 * Required env vars:
 *   JWT_PRIVATE_KEY — full PEM of the RSA private key (PKCS#1 format)
 *   JWT_PUBLIC_KEY  — full PEM of the RSA public key (SPKI format)
 */
export function loadKeys(env: Record<string, string | undefined>): RsaKeyPair {
  const rawPrivate = env['JWT_PRIVATE_KEY'];
  const rawPublic  = env['JWT_PUBLIC_KEY'];

  if (!rawPrivate) {
    throw new Error('JWT_PRIVATE_KEY environment variable is required');
  }
  if (!rawPublic) {
    throw new Error('JWT_PUBLIC_KEY environment variable is required');
  }

  // Dotenv and many CI tools store multi-line values with literal \n.
  // Convert to actual newlines so the PEM is valid for Node crypto.
  const privateKey = rawPrivate.replace(/\\n/g, '\n');
  const publicKey  = rawPublic.replace(/\\n/g, '\n');

  return { privateKey, publicKey };
}
