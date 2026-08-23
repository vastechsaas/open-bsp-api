import type { ConfirmChannel, ConsumeMessage } from "amqplib";
import { type IntegrationEvent, integrationEventSchema } from "./contracts.js";
import type { ForwardResult } from "./forwarder.js";
import type { Logger } from "./logger.js";
import type { WorkerState } from "./state.js";
import { topology } from "./topology.js";

export type ForwardEvent = (event: IntegrationEvent) => Promise<ForwardResult>;

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
}: {
  channel: ConfirmChannel;
  forward: ForwardEvent;
  logger: Logger;
  state: WorkerState;
}) {
  return async (message: ConsumeMessage | null) => {
    if (!message) return;
    state.inFlight = true;
    try {
      let input: unknown;
      try {
        input = JSON.parse(message.content.toString("utf8"));
      } catch {
        await deadLetter(channel, message, "message is not valid JSON");
        state.deadLettered += 1;
        state.lastFailureAt = new Date().toISOString();
        return;
      }

      const parsed = integrationEventSchema.safeParse(input);
      if (!parsed.success) {
        await deadLetter(channel, message, "event contract validation failed");
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

      const result = await forward(parsed.data);
      if (result.outcome === "success") {
        channel.ack(message);
        state.processed += 1;
        state.lastSuccessAt = new Date().toISOString();
        return;
      }

      await deadLetter(channel, message, result.reason, result.status);
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
