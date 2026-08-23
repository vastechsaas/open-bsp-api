import type { ConfirmChannel } from "amqplib";

export const topology = {
  exchange: "openbsp.integration",
  queue: "openbsp.chatbot.events.v1",
  routingKey: "chatbot.event.v1",
  deadLetterExchange: "openbsp.integration.dlx",
  deadLetterQueue: "openbsp.chatbot.events.dlq.v1",
  deadLetterRoutingKey: "chatbot.event.dlq.v1",
} as const;

export async function assertTopology(channel: ConfirmChannel) {
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
}
