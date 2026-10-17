import { describe, it, expect } from 'vitest';
import {
  RegisterRequestSchema,
  LoginRequestSchema,
  RefreshRequestSchema,
  LogoutRequestSchema,
} from '../src/modules/auth/auth.schema.js';

describe('RegisterRequestSchema', () => {
  it('accepts valid email and password', () => {
    const result = RegisterRequestSchema.safeParse({
      email: 'User@Example.COM',
      password: 'correcthorsebattery',
    });
    expect(result.success).toBe(true);
  });

  it('rejects invalid email format', () => {
    const result = RegisterRequestSchema.safeParse({
      email: 'notanemail',
      password: 'correcthorsebattery',
    });
    expect(result.success).toBe(false);
  });

  it('rejects password shorter than 10 characters', () => {
    const result = RegisterRequestSchema.safeParse({
      email: 'user@example.com',
      password: 'short',
    });
    expect(result.success).toBe(false);
  });

  it('rejects password longer than 72 characters', () => {
    const result = RegisterRequestSchema.safeParse({
      email: 'user@example.com',
      password: 'a'.repeat(73),
    });
    expect(result.success).toBe(false);
  });

  it('accepts password of exactly 10 characters', () => {
    const result = RegisterRequestSchema.safeParse({
      email: 'user@example.com',
      password: '1234567890',
    });
    expect(result.success).toBe(true);
  });

  it('accepts password of exactly 72 characters', () => {
    const result = RegisterRequestSchema.safeParse({
      email: 'user@example.com',
      password: 'a'.repeat(72),
    });
    expect(result.success).toBe(true);
  });
});

describe('LoginRequestSchema', () => {
  it('accepts valid credentials', () => {
    const result = LoginRequestSchema.safeParse({
      email: 'user@example.com',
      password: 'anypassword',
    });
    expect(result.success).toBe(true);
  });
});

describe('RefreshRequestSchema', () => {
  it('accepts a non-empty token string', () => {
    const result = RefreshRequestSchema.safeParse({ refreshToken: 'abc123' });
    expect(result.success).toBe(true);
  });
});

describe('LogoutRequestSchema', () => {
  it('accepts a non-empty token string', () => {
    const result = LogoutRequestSchema.safeParse({ refreshToken: 'abc123' });
    expect(result.success).toBe(true);
  });
});
