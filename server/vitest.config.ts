import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globalSetup: ['src/test/global-setup.ts'],
    globalTeardown: ['src/test/global-teardown.ts'],
    testTimeout: 60_000,
    hookTimeout: 60_000,
    teardownTimeout: 60_000,
    pool: 'forks',
    fileParallelism: false,
    include: ['src/**/*.test.ts', '__tests__/**/*.test.ts'],
  },
});
