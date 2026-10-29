import type { ConfirmChannel } from "amqplib";

export function names(environment: string) {
  const prefix = `openbsp.${environment}.campaign`;
  return {
    exchange: `${prefix}.v1`,
    dispatch: `${prefix}.dispatch.v1`,
    retry: `${prefix}.retry.v1`,
    dlq: `${prefix}.dlq.v1`,
  };
}
export type Topology = ReturnType<typeof names>;
export async function assertTopology(
  channel: ConfirmChannel,
  topology: Topology,
) {
  await channel.assertExchange(topology.exchange, "direct", { durable: true });
  await channel.assertQueue(topology.dispatch, {
    durable: true,
    arguments: { "x-single-active-consumer": true },
  });
  await channel.assertQueue(topology.retry, {
    durable: true,
    arguments: {
      "x-dead-letter-exchange": topology.exchange,
      "x-dead-letter-routing-key": "dispatch",
    },
  });
  await channel.assertQueue(topology.dlq, { durable: true });
  await channel.bindQueue(topology.dispatch, topology.exchange, "dispatch");
  await channel.bindQueue(topology.retry, topology.exchange, "retry");
  await channel.bindQueue(topology.dlq, topology.exchange, "dlq");
  await channel.prefetch(1);
}
