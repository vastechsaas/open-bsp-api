import { type ChannelModel, type ConfirmChannel, connect } from "amqplib";
import { createServer } from "node:http";
import { once } from "node:events";
import { loadConfig } from "./contracts.js";
import { assertTopology, names } from "./topology.js";
import { createBackend } from "./backend.js";
import { createConsumer, publishJob } from "./worker.js";

const config = loadConfig(process.env);
const topology = names(config.environment);
const backend = createBackend(
  config.url,
  config.serviceKey,
  fetch,
  config.dispatchKey,
);
const log = (event: string, fields: Record<string, unknown> = {}) =>
  console.log(
    JSON.stringify({ time: new Date().toISOString(), event, ...fields }),
  );
let stopping = false;
let ready = false;
let inFlight = 0;
let connection: ChannelModel | undefined;
let channel: ConfirmChannel | undefined;
let consumerTag: string | undefined;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const health = createServer((req, res) => {
  res.writeHead(
    req.url === "/healthz" || (req.url === "/readyz" && ready && !stopping)
      ? 200
      : 503,
    { "Content-Type": "application/json" },
  );
  res.end(
    JSON.stringify({
      ready,
      stopping,
      in_flight: inFlight,
      environment: config.environment,
    }),
  );
});
health.listen(config.port, "0.0.0.0");
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.once(signal, () => {
    stopping = true;
    ready = false;
  });
}

while (!stopping) {
  let active = true;
  try {
    connection = await connect(config.broker);
    channel = await connection.createConfirmChannel();
    const currentChannel = channel;
    await assertTopology(currentChannel, topology);
    currentChannel.on("error", () => {
      active = false;
      ready = false;
    });
    currentChannel.on("close", () => {
      active = false;
      ready = false;
    });
    connection.on("error", () => {
      active = false;
      ready = false;
    });
    connection.on("close", () => {
      active = false;
      ready = false;
    });
    const consume = createConsumer(currentChannel, topology, backend, log);
    const consumer = await currentChannel.consume(
      topology.dispatch,
      (message) => {
        if (!message) {
          active = false;
          return;
        }
        inFlight++;
        void consume(message).catch(() => {
          log("campaign_consumer_unavailable");
          // Close/reconnect rather than a tight immediate nack/requeue loop.
          active = false;
        }).finally(() => {
          inFlight--;
        });
      },
      { noAck: false },
    );
    consumerTag = consumer.consumerTag;
    while (active && !stopping) {
      try {
        await backend.recover();
        for (const job of await backend.publications()) {
          if (stopping || !active) break;
          await publishJob(currentChannel, topology, backend, job);
        }
        ready = true;
      } catch {
        ready = false;
        log("campaign_publisher_unavailable");
      }
      await sleep(5_000);
    }
  } catch {
    log("campaign_broker_unavailable");
  } finally {
    ready = false;
    if (channel && consumerTag) {
      await channel.cancel(consumerTag).catch(() => {});
    }
    const deadline = Date.now() + 30_000;
    while (inFlight > 0 && Date.now() < deadline) await sleep(100);
    await channel?.close().catch(() => {});
    await connection?.close().catch(() => {});
    channel = undefined;
    connection = undefined;
    consumerTag = undefined;
  }
  if (!stopping) await sleep(5_000);
}
health.close();
await once(health, "close");
