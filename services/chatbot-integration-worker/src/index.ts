import { once } from "node:events";
import { type ChannelModel, type ConfirmChannel, connect } from "amqplib";
import { loadConfig } from "./config.js";
import { createForwarder } from "./forwarder.js";
import { startHealthServer } from "./health.js";
import { createLogger } from "./logger.js";
import { createRawEventStore } from "./raw-event-store.js";
import { createWorkerState } from "./state.js";
import { assertTopology } from "./topology.js";
import { createMessageHandler } from "./worker.js";

const reconnectDelayMs = 5_000;

async function closeSession(
  connection: ChannelModel | undefined,
  channel: ConfirmChannel | undefined,
  consumerTag: string | undefined,
) {
  if (channel && consumerTag) {
    await channel.cancel(consumerTag).catch(() => undefined);
  }
  if (channel) await channel.close().catch(() => undefined);
  if (connection) await connection.close().catch(() => undefined);
}

async function waitForInFlight(state: { inFlight: boolean }) {
  const deadline = Date.now() + 15_000;
  while (state.inFlight && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

async function main() {
  const config = loadConfig();
  const logger = createLogger(config.logLevel);
  const state = createWorkerState();
  const storeRawEvent = createRawEventStore({
    supabaseUrl: config.supabaseUrl,
    serviceRoleKey: config.supabaseServiceRoleKey,
    queueName: config.topology.queue,
  });
  const healthServer = await startHealthServer(state, config.port);
  const forward = createForwarder({
    functionsBaseUrl: config.functionsBaseUrl,
    accounts: config.accounts,
    logger,
  });
  let connection: ChannelModel | undefined;
  let channel: ConfirmChannel | undefined;
  let consumerTag: string | undefined;

  const shutdown = async (signal: string) => {
    if (state.shuttingDown) return;
    state.shuttingDown = true;
    state.consuming = false;
    logger.info("Worker shutting down", { signal });
    if (channel && consumerTag) {
      await channel.cancel(consumerTag).catch(() => undefined);
      consumerTag = undefined;
    }
    await waitForInFlight(state);
    await closeSession(connection, channel, undefined);
    await new Promise<void>((resolve) => healthServer.close(() => resolve()));
  };

  process.once("SIGTERM", () => void shutdown("SIGTERM"));
  process.once("SIGINT", () => void shutdown("SIGINT"));

  while (!state.shuttingDown) {
    try {
      connection = await connect(config.cloudAmqpUrl);
      channel = await connection.createConfirmChannel();
      await assertTopology(channel, config.topology);
      const handleMessage = createMessageHandler({
        channel,
        forward,
        logger,
        state,
        topology: config.topology,
        acceptedEventTypes: config.acceptedEventTypes,
        storeRawEvent,
      });
      const consumer = await channel.consume(
        config.topology.queue,
        (message) => {
          void handleMessage(message);
        },
        { noAck: false },
      );
      consumerTag = consumer.consumerTag;
      state.connected = true;
      state.consuming = true;
      logger.info("CloudAMQP consumer ready", {
        queue: config.topology.queue,
        prefetch: 1,
      });
      await Promise.race([
        once(connection, "close"),
        once(connection, "error"),
      ]);
    } catch (error) {
      logger.error("CloudAMQP session failed", {
        error: error instanceof Error ? error.name : "unknown error",
      });
    } finally {
      state.connected = false;
      state.consuming = false;
      consumerTag = undefined;
      await closeSession(connection, channel, undefined);
      connection = undefined;
      channel = undefined;
    }

    if (!state.shuttingDown) {
      await new Promise((resolve) => setTimeout(resolve, reconnectDelayMs));
    }
  }
}

main().catch((error: unknown) => {
  console.error(JSON.stringify({
    timestamp: new Date().toISOString(),
    level: "error",
    message: "Worker failed to start",
    error: error instanceof Error ? error.name : "unknown error",
  }));
  process.exitCode = 1;
});
