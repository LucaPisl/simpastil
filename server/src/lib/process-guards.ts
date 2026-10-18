/**
 * Turns an unhandled error into one explained log line instead of a raw stack
 * trace, then exits non-zero.
 *
 * Node prints the full error, including its message, for an uncaught
 * exception. That message can carry query parameters or file paths, so the
 * entrypoints install this guard first: the line says what kind of failure it
 * was and where, using the same allowlisted cause as every other log line.
 */
import { logProcessFailure, type ProcessRole } from './process-log.js';

/** The part of `process` the guard needs, so tests can pass a fake one. */
export interface GuardedProcess {
  on(event: 'uncaughtException' | 'unhandledRejection', listener: (reason: unknown) => void): unknown;
  exit(code?: number): unknown;
}

const installed = new WeakSet<object>();

export function installProcessGuards(role: ProcessRole, target: GuardedProcess = process): void {
  if (installed.has(target)) return;
  installed.add(target);
  let crashing = false;
  const crash = (reason: unknown): void => {
    // A second failure while exiting must not log again or hide the first.
    if (crashing) return;
    crashing = true;
    try {
      logProcessFailure('process.crashed', reason, { role });
    } finally {
      target.exit(1);
    }
  };
  target.on('uncaughtException', crash);
  target.on('unhandledRejection', crash);
}
