import { type ChannelModel, type ConfirmChannel, connect } from "amqplib";
import { loadConfig } from "./config.js";
import { createForwarder } from "./forwarder.js";
import { startHealthServer } from "./health.js";
import { createLogger } from "./logger.js";
import { createRawEventStore } from "./raw-event-store.js";
import { createWorkerState } from "./state.js";
import { assertTopology, laneQueue } from "./topology.js";
import {
  createIngressHandler,
  createMessageHandler,
  parseEvent,
} from "./worker.js";
import { createConfirmedPublisher } from "./publisher.js";
import { eventReservation } from "./routing.js";
import { Scheduler } from "./scheduler.js";
import { settleWithin } from "./deadline.js";
import type { Duplex } from "node:stream";

async function main() {
  const config = loadConfig();
  const logger = createLogger(config.logLevel);
  const state = createWorkerState();
  const health = await startHealthServer(state, config.port);
  let disconnect = () => {};
  const shutdown = () => {
    state.shuttingDown = true;
    state.consuming = false;
    disconnect();
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
  while (!state.shuttingDown) {
    let connection: ChannelModel | undefined;
    const channels: ConfirmChannel[] = [];
    const consumers: Array<{ channel: ConfirmChannel; tag: string }> = [];
    const schedulers = new Set<Scheduler>();
    const abort = new AbortController();
    let endSession = () => {};
    try {
      const ended = new Promise<void>((resolve) => {
        endSession = resolve;
        disconnect = resolve;
      });
      connection = await connect(config.cloudAmqpUrl, {
        timeout: 10_000,
        heartbeat: 15,
      });
      connection.on("error", () => endSession());
      connection.on("close", () => endSession());
      const createChannel = async () => {
        const channel = await connection!.createConfirmChannel();
        channels.push(channel);
        channel.on("error", () => endSession());
        channel.on("close", () => endSession());
        return channel;
      };
      const ingress = await createChannel();
      const publishing = await createChannel();
      const publish = createConfirmedPublisher(publishing);
      await assertTopology(ingress, config.topology);
      // Publication is synchronous up to sendToQueue, preserving ingress order;
      // confirms may be pipelined without serializing a broker network RTT.
      await ingress.prefetch(32);
      const forward = createForwarder({
        functionsBaseUrl: config.functionsBaseUrl,
        accounts: config.accounts,
        logger,
        edgeRegion: config.edgeRegion,
        signal: abort.signal,
      });
      const storeRawEvent = createRawEventStore({
        supabaseUrl: config.supabaseUrl,
        serviceRoleKey: config.supabaseServiceRoleKey,
        queueName: config.topology.queue,
        signal: abort.signal,
      });
      const serial = config.mode === "serial" ? new Scheduler(1) : undefined;
      if (serial) schedulers.add(serial);
      for (const lane of ["messages", "statuses"] as const) {
        const channel = await createChannel();
        const limit = lane === "messages"
          ? config.messageConcurrency
          : config.statusConcurrency;
        await channel.prefetch(config.mode === "serial" ? 1 : limit * 4);
        const scheduler = serial ?? new Scheduler(limit);
        schedulers.add(scheduler);
        const handle = createMessageHandler({
          channel,
          forward,
          storeRawEvent,
          publish,
          logger,
          state,
          topology: config.topology,
          acceptedEventTypes: config.acceptedEventTypes,
          lane,
        });
        const consumer = await channel.consume(
          laneQueue(config.topology, lane),
          (message) => {
            if (!message) {
              endSession();
              return;
            }
            const received = Date.now();
            const parsed = parseEvent(message);
            const reservation = config.mode === "serial"
              ? { integration: "*", keys: [] }
              : parsed?.success
              ? eventReservation(parsed.data)
              : { integration: "*", keys: [] };
            let started = false;
            state.lanes[lane].pending++;
            void scheduler.enqueue(reservation, async () => {
              started = true;
              state.lanes[lane].pending--;
              state.lanes[lane].active++;
              try {
                await handle(message, received);
              } finally {
                state.lanes[lane].active--;
              }
            }).catch(() => undefined).finally(() => {
              if (!started) state.lanes[lane].pending--;
            });
          },
          { noAck: false },
        );
        consumers.push({ channel, tag: consumer.consumerTag });
        state.lanes[lane].consuming = true;
      }
      const route = createIngressHandler({
        channel: ingress,
        publish,
        topology: config.topology,
        logger,
        state,
      });
      const source = await ingress.consume(config.topology.queue, (message) => {
        if (!message) {
          endSession();
          return;
        }
        void route(message).catch(() => endSession());
      }, { noAck: false });
      consumers.push({ channel: ingress, tag: source.consumerTag });
      state.connected = true;
      state.consuming = true;
      logger.info("CloudAMQP lane consumers ready", {
        mode: config.mode,
        message_concurrency: config.messageConcurrency,
        status_concurrency: config.statusConcurrency,
        edge_region: config.edgeRegion,
      });
      await ended;
    } catch {
      logger.error("CloudAMQP session failed");
    } finally {
      state.connected = false;
      state.consuming = false;
      for (const lane of Object.values(state.lanes)) lane.consuming = false;
      const deadline = Date.now() + 45_000;
      // Stop local scheduling immediately, even when broker cancellation stalls.
      for (const scheduler of schedulers) scheduler.stop();
      await settleWithin(
        Promise.all(
          consumers.map(({ channel, tag }) =>
            channel.cancel(tag).catch(() => undefined)
          ),
        ),
        1_000,
      );
      while (state.inFlight && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      abort.abort();
      await settleWithin(
        Promise.all(
          channels.map((channel) => channel.close().catch(() => undefined)),
        ),
        2_000,
      );
      if (connection && !await settleWithin(connection.close(), 2_000)) {
        // amqplib 0.10.8 exposes the underlying stream on its Connection.
        // Break a stalled close handshake so unacknowledged deliveries recover.
        (connection.connection as typeof connection.connection & {
          stream: Duplex;
        }).stream.destroy();
      }
      if (!state.shuttingDown) {
        await new Promise((resolve) => setTimeout(resolve, 5_000));
      }
    }
  }
  await new Promise<void>((resolve) => health.close(() => resolve()));
}
main().catch(() => {
  console.error("Worker startup failed");
  process.exitCode = 1;
});
