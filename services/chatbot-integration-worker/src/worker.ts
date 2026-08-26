import type { ConfirmChannel, ConsumeMessage } from "amqplib";
import { type IntegrationEvent, integrationEventSchema } from "./contracts.js";
import type { ForwardResult } from "./forwarder.js";
import type { Logger } from "./logger.js";
import type { StoreRawEvent } from "./raw-event-store.js";
import type { WorkerState } from "./state.js";
import { defaultTopology, type QueueTopology } from "./topology.js";

export type ForwardEvent = (event: IntegrationEvent) => Promise<ForwardResult>;

type WebhookSummary = {
  phone_number_ids: string[];
  messages_count: number;
  statuses_count: number;
  message_types: string[];
  message_wamids: string[];
};

export function summarizeWhatsAppWebhook(rawBody: string): WebhookSummary {
  const summary: WebhookSummary = {
    phone_number_ids: [],
    messages_count: 0,
    statuses_count: 0,
    message_types: [],
    message_wamids: [],
  };

  const body = JSON.parse(rawBody) as {
    entry?: Array<{
      changes?: Array<{
        value?: {
          metadata?: { phone_number_id?: unknown };
          messages?: Array<{ id?: unknown; type?: unknown }>;
          statuses?: unknown[];
        };
      }>;
    }>;
  };

  for (const entry of body.entry ?? []) {
    for (const change of entry.changes ?? []) {
      const value = change.value;
      if (!value) continue;

      if (typeof value.metadata?.phone_number_id === "string") {
        summary.phone_number_ids.push(value.metadata.phone_number_id);
      }

      const messages = Array.isArray(value.messages) ? value.messages : [];
      const statuses = Array.isArray(value.statuses) ? value.statuses : [];
      summary.messages_count += messages.length;
      summary.statuses_count += statuses.length;

      for (const message of messages) {
        if (typeof message.type === "string") {
          summary.message_types.push(message.type);
        }
        if (typeof message.id === "string") {
          summary.message_wamids.push(message.id);
        }
      }
    }
  }

  summary.phone_number_ids = [...new Set(summary.phone_number_ids)];
  summary.message_types = [...new Set(summary.message_types)];
  summary.message_wamids = [...new Set(summary.message_wamids)];
  return summary;
}

function failureRecord(
  message: ConsumeMessage,
  reason: string,
  status?: number,
) {
  let original: unknown;
  try {
    original = JSON.parse(message.content.toString("utf8")) as unknown;
  } catch {
    original = { encoded_message: message.content.toString("base64") };
  }
  return Buffer.from(JSON.stringify({
    event: original,
    failure: {
      reason,
      status,
      failed_at: new Date().toISOString(),
    },
  }));
}

async function deadLetter(
  channel: ConfirmChannel,
  message: ConsumeMessage,
  reason: string,
  topology: QueueTopology,
  status?: number,
) {
  channel.publish(
    topology.deadLetterExchange,
    topology.deadLetterRoutingKey,
    failureRecord(message, reason, status),
    {
      persistent: true,
      contentType: "application/json",
      messageId: typeof message.properties.messageId === "string"
        ? message.properties.messageId
        : undefined,
      timestamp: Date.now(),
      headers: {
        failure_reason: reason,
        ...(status === undefined ? {} : { failure_status: status }),
      },
    },
  );
  await channel.waitForConfirms();
  channel.ack(message);
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
}: {
  channel: ConfirmChannel;
  forward: ForwardEvent;
  logger: Logger;
  state: WorkerState;
  topology?: QueueTopology;
  acceptedEventTypes?: ReadonlySet<IntegrationEvent["event_type"]>;
  storeRawEvent?: StoreRawEvent;
}) {
  return async (message: ConsumeMessage | null) => {
    if (!message) return;
    state.inFlight = true;
    try {
      const rawPayload = message.content.toString("utf8");
      await storeRawEvent(rawPayload);

      let input: unknown;
      try {
        input = JSON.parse(rawPayload);
      } catch {
        await deadLetter(
          channel,
          message,
          "message is not valid JSON",
          topology,
        );
        state.deadLettered += 1;
        state.lastFailureAt = new Date().toISOString();
        return;
      }

      const parsed = integrationEventSchema.safeParse(input);
      if (!parsed.success) {
        await deadLetter(
          channel,
          message,
          "event contract validation failed",
          topology,
        );
        state.deadLettered += 1;
        state.lastFailureAt = new Date().toISOString();
        logger.warn("Event sent to dead-letter queue", {
          event_id: typeof input === "object" && input && "event_id" in input
            ? input.event_id
            : undefined,
          reason: "event contract validation failed",
        });
        return;
      }

      if (!acceptedEventTypes.has(parsed.data.event_type)) {
        await deadLetter(
          channel,
          message,
          "event type is not enabled for this worker instance",
          topology,
        );
        state.deadLettered += 1;
        state.lastFailureAt = new Date().toISOString();
        return;
      }

      if (parsed.data.event_type === "whatsapp_webhook") {
        logger.info("WhatsApp webhook event received from queue", {
          event_id: parsed.data.event_id,
          integration_key: parsed.data.integration_key,
          ...summarizeWhatsAppWebhook(parsed.data.payload.raw_body),
        });
      }

      const result = await forward(parsed.data);
      if (result.outcome === "success") {
        channel.ack(message);
        state.processed += 1;
        state.lastSuccessAt = new Date().toISOString();
        return;
      }

      await deadLetter(
        channel,
        message,
        result.reason,
        topology,
        result.status,
      );
      state.deadLettered += 1;
      state.lastFailureAt = new Date().toISOString();
      logger.warn("Event sent to dead-letter queue", {
        event_id: parsed.data.event_id,
        event_type: parsed.data.event_type,
        integration_key: parsed.data.integration_key,
        attempts: result.attempts,
        response_status: result.status,
        reason: result.reason,
      });
    } catch (error) {
      logger.error("Unexpected worker processing failure", {
        error: error instanceof Error ? error.name : "unknown error",
      });
      channel.nack(message, false, true);
    } finally {
      state.inFlight = false;
    }
  };
}
