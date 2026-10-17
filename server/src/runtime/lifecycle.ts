export interface LifecycleCoordinatorOptions {
  timeoutMs: number;
  stopWork?: (deadlineMs: number) => void | boolean | Promise<void | boolean>;
  stopAccepting: () => Promise<void>;
  forceClose: () => void;
  closeResources: (remainingMs: number) => Promise<void>;
}

type DeadlineResult<T> = { completed: true; value: T } | { completed: false };

async function beforeDeadline<T>(promise: Promise<T>, deadlineMs: number): Promise<DeadlineResult<T>> {
  const remainingMs = Math.max(0, deadlineMs - Date.now());
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      promise.then(
        (value): DeadlineResult<T> => ({ completed: true, value }),
        (): DeadlineResult<T> => ({ completed: false }),
      ),
      new Promise<DeadlineResult<T>>((resolve) => {
        timer = setTimeout(() => resolve({ completed: false }), remainingMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** One idempotent, deadline-bounded shutdown path shared by runtime entrypoints. */
export function createLifecycleCoordinator(options: LifecycleCoordinatorOptions): {
  shutdown(): Promise<boolean>;
} {
  let shutdownPromise: Promise<boolean> | undefined;
  return {
    shutdown(): Promise<boolean> {
      if (shutdownPromise) return shutdownPromise;
      shutdownPromise = (async () => {
        const deadlineMs = Date.now() + options.timeoutMs;
        let clean = true;
        if (options.stopWork) {
          const stopped = await beforeDeadline(Promise.resolve().then(() => options.stopWork!(deadlineMs)), deadlineMs);
          if (!stopped.completed || stopped.value === false) {
            clean = false;
            options.forceClose();
          }
        }

        const listenerClosed = await beforeDeadline(options.stopAccepting(), deadlineMs);
        if (!listenerClosed.completed) {
          clean = false;
          options.forceClose();
        }

        const remainingMs = Math.max(0, deadlineMs - Date.now());
        const resourcesClosed = await beforeDeadline(options.closeResources(remainingMs), deadlineMs);
        if (!resourcesClosed.completed) {
          clean = false;
          options.forceClose();
        }
        return clean;
      })();
      return shutdownPromise;
    },
  };
}
