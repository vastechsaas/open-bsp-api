import { assertEquals } from "../test_assert.ts";
import { lifecycleFresh } from "./lifecycle_snapshot.ts";
import { boundedWork } from "./bounded_work.ts";

Deno.test("last-confirmed snapshot freshness never accepts missing, future or expired confirmations", () => {
  const now = Date.parse("2026-10-11T00:01:00Z");
  assertEquals(lifecycleFresh(undefined, now), false);
  assertEquals(lifecycleFresh("invalid", now), false);
  assertEquals(lifecycleFresh("2026-10-11T00:00:00Z", now), true);
  assertEquals(lifecycleFresh("2026-10-10T23:59:59Z", now), false);
  assertEquals(lifecycleFresh("2026-10-11T00:01:01Z", now), false);
});

Deno.test("recovery starts at most three operations and leaves unstarted work durable at deadline", async () => {
  let active = 0, peak = 0, started = 0;
  await boundedWork(
    [1, 2, 3, 4, 5, 6, 7],
    async (_item, signal) => {
      active++;
      started++;
      peak = Math.max(peak, active);
      await new Promise<void>((resolve) =>
        signal.addEventListener("abort", () => resolve(), { once: true })
      );
      active--;
    },
    30,
    3,
  );
  assertEquals(peak, 3);
  assertEquals(started, 3);
});

Deno.test("recovery budget also bounds an unresponsive database handler", async () => {
  const startedAt = Date.now();
  let started = 0;
  await boundedWork(
    [1, 2, 3, 4],
    () => {
      started++;
      return new Promise<void>(() => {});
    },
    30,
    3,
  );
  assertEquals(started, 3);
  assertEquals(Date.now() - startedAt < 1000, true);
});
