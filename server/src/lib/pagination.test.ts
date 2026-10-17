import { describe, expect, it } from 'vitest';
import { MAX_LIMIT, parsePagination } from './pagination.js';

describe('parsePagination', () => {
  it('uses bounded defaults and accepts zero offset', () => {
    expect(parsePagination({})).toEqual({ limit: 50, offset: 0 });
    expect(parsePagination({ limit: String(MAX_LIMIT), offset: '0' })).toEqual({
      limit: MAX_LIMIT,
      offset: 0,
    });
  });

  it.each([
    { limit: '0' },
    { limit: '-1' },
    { limit: '1.5' },
    { limit: '10abc' },
    { limit: '1e2' },
    { limit: String(MAX_LIMIT + 1) },
    { offset: '-1' },
    { offset: '1.5' },
    { offset: '10abc' },
    { offset: '9'.repeat(40) },
  ])('rejects unsafe pagination input %o', (query) => {
    expect(() => parsePagination(query)).toThrow();
  });
});
