export async function boundedWork<T>(
  items: T[],
  handler: (item: T, signal: AbortSignal) => Promise<void>,
  budgetMs = 45_000,
  concurrency = 3,
) {
  const controller = new AbortController();
  const signal = controller.signal;
  let timer: ReturnType<typeof setTimeout>;
  const deadline = new Promise<void>((resolve) => {
    timer = setTimeout(() => {
      controller.abort();
      resolve();
    }, budgetMs);
  });
  let cursor = 0;
  const workers = Promise.all(
    Array.from({ length: Math.min(concurrency, items.length) }, async () => {
      while (!signal.aborted && cursor < items.length) {
        const item = items[cursor++];
        try {
          await handler(item, signal);
        } catch { /* Durable lease/reconciliation recovers this work. */ }
      }
    }),
  );
  try {
    await Promise.race([workers, deadline]);
  } finally {
    clearTimeout(timer!);
  }
}
