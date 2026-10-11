export function brokerConnection(address: string) {
  const url = new URL(address);
  // amqplib reads heartbeat from AMQP connection fields, not socket options.
  if (!url.searchParams.has("heartbeat")) {
    url.searchParams.set("heartbeat", "15");
  }
  return {
    url: url.toString(),
    socket: {
      timeout: 10_000,
      noDelay: true,
      keepAlive: true,
      keepAliveDelay: 10_000,
    },
  };
}
