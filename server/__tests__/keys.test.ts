import { describe, it, expect } from 'vitest';
import { loadKeys } from '../src/config/keys.js';

const FAKE_PRIVATE = '-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----';
const FAKE_PUBLIC  = '-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----';

describe('loadKeys()', () => {
  it('throws if JWT_PRIVATE_KEY is missing', () => {
    expect(() => loadKeys({ JWT_PUBLIC_KEY: FAKE_PUBLIC }))
      .toThrow('JWT_PRIVATE_KEY');
  });

  it('throws if JWT_PUBLIC_KEY is missing', () => {
    expect(() => loadKeys({ JWT_PRIVATE_KEY: FAKE_PRIVATE }))
      .toThrow('JWT_PUBLIC_KEY');
  });

  it('normalises literal \\n escape sequences to real newlines', () => {
    const keys = loadKeys({
      JWT_PRIVATE_KEY: FAKE_PRIVATE.replace(/\n/g, '\\n'),
      JWT_PUBLIC_KEY:  FAKE_PUBLIC.replace(/\n/g, '\\n'),
    });
    expect(keys.privateKey).toContain('\n');
    expect(keys.publicKey).toContain('\n');
  });

  it('returns PEM strings unchanged when newlines are already real', () => {
    const keys = loadKeys({
      JWT_PRIVATE_KEY: FAKE_PRIVATE,
      JWT_PUBLIC_KEY:  FAKE_PUBLIC,
    });
    expect(keys.privateKey).toBe(FAKE_PRIVATE);
    expect(keys.publicKey).toBe(FAKE_PUBLIC);
  });
});
