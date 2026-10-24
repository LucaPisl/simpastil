import { describe, expect, it } from 'vitest';
import { constraintOf, isUniqueViolation, sqlStateOf } from './pg-errors.js';

describe('SQLSTATE lookup', () => {
  const driverError = Object.assign(new Error('duplicate key value'), { code: '23505' });

  it('reads the code from a bare driver error', () => {
    expect(sqlStateOf(driverError)).toBe('23505');
    expect(isUniqueViolation(driverError)).toBe(true);
  });

  it('looks through the Drizzle query wrapper to the driver error', () => {
    const wrapped = new Error('Failed query: insert into "users"', { cause: driverError });
    expect(sqlStateOf(wrapped)).toBe('23505');
    expect(isUniqueViolation(wrapped)).toBe(true);
  });

  it('does not treat other states, symbolic codes or non-errors as unique violations', () => {
    expect(isUniqueViolation(Object.assign(new Error('x'), { code: '23503' }))).toBe(false);
    expect(isUniqueViolation(Object.assign(new Error('x'), { code: 'ECONNREFUSED' }))).toBe(false);
    expect(isUniqueViolation(new Error('x', { cause: new Error('y') }))).toBe(false);
    expect(isUniqueViolation(null)).toBe(false);
    expect(isUniqueViolation('23505')).toBe(false);
  });

  it('stops following a cyclic cause chain', () => {
    const a: { cause?: unknown } = {};
    a.cause = a;
    expect(sqlStateOf(a)).toBeUndefined();
  });
});

describe('constraint name lookup', () => {
  const driverError = Object.assign(new Error('violates check constraint'), {
    code: '23514', constraint_name: 'account_settings_value_size_check',
  });

  it('reads the name from a bare driver error', () => {
    expect(constraintOf(driverError)).toBe('account_settings_value_size_check');
  });

  it('looks through the Drizzle wrapper and several levels of cause', () => {
    const wrapped = new Error('Failed query', { cause: new Error('outer', { cause: driverError }) });
    expect(constraintOf(wrapped)).toBe('account_settings_value_size_check');
  });

  it('never reads the name out of the message text', () => {
    expect(constraintOf(new Error('violates check constraint "account_settings_value_size_check"'))).toBeUndefined();
  });

  it('returns nothing for a non-string name, a missing name, a non-error or a cyclic chain', () => {
    expect(constraintOf(Object.assign(new Error('x'), { constraint_name: 42 }))).toBeUndefined();
    expect(constraintOf(new Error('x', { cause: new Error('y') }))).toBeUndefined();
    expect(constraintOf(null)).toBeUndefined();
    expect(constraintOf('account_settings_value_size_check')).toBeUndefined();
    const a: { cause?: unknown } = {};
    a.cause = a;
    expect(constraintOf(a)).toBeUndefined();
  });

  it('gives up beyond the depth limit', () => {
    let deep: unknown = driverError;
    for (let i = 0; i < 6; i += 1) deep = { cause: deep };
    expect(constraintOf(deep)).toBeUndefined();
  });
});
