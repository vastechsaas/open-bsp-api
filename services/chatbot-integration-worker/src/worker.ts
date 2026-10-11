import type { ConfirmChannel, ConsumeMessage } from "amqplib";
import { type IntegrationEvent, integrationEventSchema } from "./contracts.js";
import type { ForwardResult } from "./forwarder.js";
import type { Logger } from "./logger.js";
import type { StoreRawEvent } from "./raw-event-store.js";
import type { WorkerState } from "./state.js";
import {
  defaultTopology,
  laneQueue,
  type QueueTopology,
  retryDelaysMs,
  retryQueue,
} from "./topology.js";
import {
  createConfirmedPublisher,
  type PublishConfirmed,
} from "./publisher.js";
import { eventLane, type Lane } from "./routing.js";

export type ForwardEvent = (event: IntegrationEvent) => Promise<ForwardResult>;
export function parseEvent(message: ConsumeMessage) {
  try {
    return integrationEventSchema.safeParse(
      JSON.parse(message.content.toString("utf8")),
    );
  } catch {
    return undefined;
  }
}

export function createIngressHandler(
  { channel, publish, topology, state, logger }: {
    channel: ConfirmChannel;
    publish: PublishConfirmed;
    topology: QueueTopology;
    state: WorkerState;
    logger: Logger;
  },
) {
  return async (message: ConsumeMessage | null) => {
    if (!message) return;
    state.inFlight++;
    try {
      const parsed = parseEvent(message);
      const lane = parsed?.success ? eventLane(parsed.data) : "messages";
      await publish(
        laneQueue(topology, lane),
        message.content,
        message.properties,
      );
      channel.ack(message);
      state.routed++;
    } catch {
      logger.error("Ingress durable routing failed");
      channel.nack(message, false, true);
    } finally {
      state.inFlight--;
    }
  };
}

export function createMessageHandler({
  channel,
  forward,
  logger,
  state,
  topology = defaultTopology,
  acceptedEventTypes = new Set<IntegrationEvent["event_type"]>([
    "whatsapp_webhook",
    "chatbot_reply",
  ]),
  storeRawEvent = () => Promise.resolve(),
  publish = createConfirmedPublisher(channel),
  lane = "messages",
}: {
  channel: ConfirmChannel;
  forward: ForwardEvent;
  logger: Logger;
  state: WorkerState;
  topology?: QueueTopology;
  acceptedEventTypes?: ReadonlySet<IntegrationEvent["event_type"]>;
  storeRawEvent?: StoreRawEvent;
  publish?: PublishConfirmed;
  lane?: Lane;
}) {
  return async (message: ConsumeMessage | null, receivedAt = Date.now()) => {
    if (!message) return;
    state.inFlight++;
    const started = Date.now();
    const parsed = parseEvent(message);
    const event = parsed?.success ? parsed.data : undefined;
    const suppliedRetry: unknown = message.properties.headers
      ?.["x-openbsp-retry"];
    const retries =
      typeof suppliedRetry === "number" && Number.isInteger(suppliedRetry) &&
        suppliedRetry >= 0 && suppliedRetry <= 5
        ? suppliedRetry
        : suppliedRetry === undefined
        ? 0
        : 5;
    let rawStoreMs = 0;
    const fields = {
      event_id: event?.event_id,
      event_type: event?.event_type,
      lane,
      retry_count: retries,
    };
    const settleFailure = async (
      reason: string,
      retryable: boolean,
      status?: number,
    ) => {
      if (retryable && retries < retryDelaysMs.length) {
        await publish(
          retryQueue(topology, lane, retries + 1),
          message.content,
          {
            ...message.properties,
            headers: {
              ...message.properties.headers,
              "x-openbsp-retry": retries + 1,
            },
          },
        );
        state.retried++;
        logger.warn("Event scheduled for durable retry", {
          ...fields,
          reason,
          response_status: status,
          retry_delay_ms: retryDelaysMs[retries],
        });
      } else {
        await publish(topology.deadLetterQueue, message.content, {
          ...message.properties,
          headers: {
            ...message.properties.headers,
            failure_reason: reason,
            ...(status === undefined ? {} : { failure_status: status }),
          },
        });
        state.deadLettered++;
        logger.warn("Event sent to dead-letter queue", {
          ...fields,
          reason,
          response_status: status,
        });
      }
      state.lastFailureAt = new Date().toISOString();
      channel.ack(message);
    };
    try {
      try {
        const rawStarted = Date.now();
        await storeRawEvent(message.content.toString("utf8"));
        rawStoreMs = Date.now() - rawStarted;
      } catch {
        await settleFailure("raw-event storage unavailable", true);
        return;
      }
      if (!event || !acceptedEventTypes.has(event.event_type)) {
        await settleFailure("event contract invalid or type disabled", false);
        return;
      }
      let result: ForwardResult;
      try {
        result = await forward(event);
      } catch {
        result = {
          outcome: "permanent_failure",
          reason: "unexpected forwarding failure",
          attempts: 1,
        };
      }
      if (result.outcome === "success") {
        channel.ack(message);
        state.processed++;
        state.lastSuccessAt = new Date().toISOString();
        return;
      }
      await settleFailure(
        result.reason,
        result.status === undefined || result.status === 429 ||
          result.status >= 500,
        result.status,
      );
    } catch {
      logger.error("Durable event settlement failed", fields);
      channel.nack(message, false, true);
    } finally {
      logger.info("Integration event processing completed", {
        ...fields,
        scheduling_wait_ms: started - receivedAt,
        raw_store_ms: rawStoreMs,
        event_age_at_receipt_ms: event
          ? Math.max(0, receivedAt - Date.parse(event.occurred_at))
          : undefined,
        total_event_age_ms: event
          ? Math.max(0, Date.now() - Date.parse(event.occurred_at))
          : undefined,
        processing_ms: Date.now() - started,
      });
      state.inFlight--;
    }
  };
}
