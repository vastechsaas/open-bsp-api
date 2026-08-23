import assert from "node:assert/strict";
import test from "node:test";
import type { ConfirmChannel } from "amqplib";
import { assertTopology, topology } from "../src/topology.js";

test("declares durable queues, dead lettering, single consumer and prefetch one", async () => {
  const calls: Array<[string, ...unknown[]]> = [];
  const channel = {
    assertExchange: (...args: unknown[]) => {
      calls.push(["assertExchange", ...args]);
      return Promise.resolve({ exchange: String(args[0]) });
    },
    assertQueue: (...args: unknown[]) => {
      calls.push(["assertQueue", ...args]);
      return Promise.resolve({
        queue: String(args[0]),
        messageCount: 0,
        consumerCount: 0,
      });
    },
    bindQueue: (...args: unknown[]) => {
      calls.push(["bindQueue", ...args]);
      return Promise.resolve({});
    },
    prefetch: (...args: unknown[]) => {
      calls.push(["prefetch", ...args]);
      return Promise.resolve({});
    },
  } as unknown as ConfirmChannel;

  await assertTopology(channel);
  const mainQueue = calls.find(
    ([method, queue]) => method === "assertQueue" && queue === topology.queue,
  );
  assert.deepEqual(mainQueue?.[2], {
    durable: true,
    arguments: {
      "x-single-active-consumer": true,
      "x-dead-letter-exchange": topology.deadLetterExchange,
      "x-dead-letter-routing-key": topology.deadLetterRoutingKey,
    },
  });
  assert.ok(
    calls.some(([method, count]) => method === "prefetch" && count === 1),
  );
});
