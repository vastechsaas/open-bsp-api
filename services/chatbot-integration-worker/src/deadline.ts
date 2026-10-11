// Broker cancellation/close RPCs can hang during a broken connection. They
// must not consume an unbounded amount of the shutdown grace period.
export async function settleWithin(
  work: Promise<unknown>,
  milliseconds: number,
): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work.then(() => true, () => true),
      new Promise<boolean>((resolve) => {
        timer = setTimeout(() => resolve(false), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
