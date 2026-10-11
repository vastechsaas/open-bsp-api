import type { ConfirmChannel } from "amqplib";
import type { Lane } from "./routing.js";

export const retryDelaysMs = [5_000, 15_000, 30_000, 60_000, 120_000];
export const laneQueue = (topology: QueueTopology, lane: Lane) =>
  `${topology.queue}.${lane}`;
export const retryQueue = (
  topology: QueueTopology,
  lane: Lane,
  attempt: number,
) => `${laneQueue(topology, lane)}.retry.${attempt}`;

export type QueueTopology = {
  exchange: string;
  queue: string;
  routingKey: string;
  deadLetterExchange: string;
  deadLetterQueue: string;
  deadLetterRoutingKey: string;
};

export const defaultTopology: QueueTopology = {
  exchange: "openbsp.integration",
  queue: "openbsp.chatbot.events.v1",
  routingKey: "chatbot.event.v1",
  deadLetterExchange: "openbsp.integration.dlx",
  deadLetterQueue: "openbsp.chatbot.events.dlq.v1",
  deadLetterRoutingKey: "chatbot.event.dlq.v1",
};

// Backward-compatible default used by the fixture publisher and tests.
export const topology = defaultTopology;

export async function assertTopology(
  channel: ConfirmChannel,
  topology: QueueTopology = defaultTopology,
) {
  await channel.assertExchange(topology.exchange, "direct", { durable: true });
  await channel.assertExchange(topology.deadLetterExchange, "direct", {
    durable: true,
  });
  await channel.assertQueue(topology.deadLetterQueue, { durable: true });
  await channel.bindQueue(
    topology.deadLetterQueue,
    topology.deadLetterExchange,
    topology.deadLetterRoutingKey,
  );
  await channel.assertQueue(topology.queue, {
    durable: true,
    arguments: {
      "x-single-active-consumer": true,
      "x-dead-letter-exchange": topology.deadLetterExchange,
      "x-dead-letter-routing-key": topology.deadLetterRoutingKey,
    },
  });
  await channel.bindQueue(
    topology.queue,
    topology.exchange,
    topology.routingKey,
  );
  await channel.prefetch(1);
  await channel.assertQueue(`${topology.queue}.retry`, {
    durable: true,
    arguments: {
      "x-message-ttl": 30_000,
      "x-dead-letter-exchange": topology.exchange,
      "x-dead-letter-routing-key": topology.routingKey,
    },
  });
  // Never alter the existing ingress/retry queue arguments in place.
  for (const lane of ["messages", "statuses"] as const) {
    const queue = laneQueue(topology, lane);
    await channel.assertQueue(queue, {
      durable: true,
      arguments: { "x-single-active-consumer": true },
    });
    for (const [index, delay] of retryDelaysMs.entries()) {
      await channel.assertQueue(retryQueue(topology, lane, index + 1), {
        durable: true,
        arguments: {
          "x-message-ttl": delay,
          "x-dead-letter-exchange": "",
          "x-dead-letter-routing-key": queue,
        },
      });
    }
  }
}
