import assert from "node:assert/strict";
import test from "node:test";
import type { ConfirmChannel, ConsumeMessage } from "amqplib";
import { createWorkerState } from "../src/state.js";
import { createMessageHandler } from "../src/worker.js";
import type { LogFields } from "../src/logger.js";
import { replyEvent, silentLogger, webhookEvent } from "./fixtures.js";

function message(body: unknown): ConsumeMessage {
  return {
    content: Buffer.from(
      typeof body === "string" ? body : JSON.stringify(body),
    ),
    fields: {
      consumerTag: "test",
      deliveryTag: 1,
      redelivered: false,
      exchange: "openbsp.integration",
      routingKey: "chatbot.event.v1",
    },
    properties: {
      contentType: "application/json",
      contentEncoding: undefined,
      headers: {},
      deliveryMode: 2,
      priority: undefined,
      correlationId: undefined,
      replyTo: undefined,
      expiration: undefined,
      messageId: replyEvent.event_id,
      timestamp: undefined,
      type: undefined,
      userId: undefined,
      appId: undefined,
      clusterId: undefined,
    },
  };
}

function channelMock() {
  const calls = { ack: 0, nack: 0, publish: 0, confirmed: 0 };
  return {
    calls,
    channel: {
      ack: () => {
        calls.ack += 1;
      },
      nack: () => {
        calls.nack += 1;
      },
      publish: () => {
        calls.publish += 1;
        return true;
      },
      waitForConfirms: () => {
        calls.confirmed += 1;
        return Promise.resolve();
      },
    } as unknown as ConfirmChannel,
  };
}

test("acknowledges only after successful forwarding", async () => {
  const { channel, calls } = channelMock();
  const state = createWorkerState();
  let forwarded = false;
  await createMessageHandler({
    channel,
    logger: silentLogger,
    state,
    forward: () => {
      assert.equal(calls.ack, 0);
      forwarded = true;
      return Promise.resolve({ outcome: "success", status: 201, attempts: 1 });
    },
  })(message(replyEvent));
  assert.equal(forwarded, true);
  assert.equal(calls.ack, 1);
  assert.equal(state.processed, 1);
});

test("confirms dead-letter publication before acknowledging permanent failures", async () => {
  const { channel, calls } = channelMock();
  const state = createWorkerState();
  await createMessageHandler({
    channel,
    logger: silentLogger,
    state,
    forward: () =>
      Promise.resolve({
        outcome: "permanent_failure",
        status: 400,
        reason: "bad request",
        attempts: 1,
      }),
  })(message(replyEvent));
  assert.equal(calls.publish, 1);
  assert.equal(calls.confirmed, 1);
  assert.equal(calls.ack, 1);
  assert.equal(state.deadLettered, 1);
});

test("dead-letters malformed messages without forwarding", async () => {
  const { channel, calls } = channelMock();
  let forwarded = false;
  await createMessageHandler({
    channel,
    logger: silentLogger,
    state: createWorkerState(),
    forward: () => {
      forwarded = true;
      throw new Error("not expected");
    },
  })(message("not-json"));
  assert.equal(forwarded, false);
  assert.equal(calls.publish, 1);
  assert.equal(calls.ack, 1);
});

test("requeues an unexpected processing failure without acknowledging", async () => {
  const { channel, calls } = channelMock();
  await createMessageHandler({
    channel,
    logger: silentLogger,
    state: createWorkerState(),
    forward: () => Promise.reject(new Error("unexpected")),
  })(message(replyEvent));
  assert.equal(calls.ack, 0);
  assert.equal(calls.nack, 1);
});

test("dead-letters an event type disabled for this worker instance", async () => {
  const { channel, calls } = channelMock();
  let forwarded = false;
  await createMessageHandler({
    channel,
    logger: silentLogger,
    state: createWorkerState(),
    acceptedEventTypes: new Set(["whatsapp_webhook"]),
    forward: () => {
      forwarded = true;
      return Promise.resolve({ outcome: "success", status: 200, attempts: 1 });
    },
  })(message(replyEvent));
  assert.equal(forwarded, false);
  assert.equal(calls.publish, 1);
  assert.equal(calls.ack, 1);
});

test("logs a safe summary of queued WhatsApp webhook contents", async () => {
  const { channel } = channelMock();
  const infoLogs: Array<{ message: string; fields?: LogFields }> = [];
  const logger = {
    ...silentLogger,
    info(message: string, fields?: LogFields) {
      infoLogs.push({ message, fields });
    },
  };
  const event = {
    ...webhookEvent,
    payload: {
      ...webhookEvent.payload,
      raw_body: JSON.stringify({
        object: "whatsapp_business_account",
        entry: [{
          changes: [{
            value: {
              metadata: { phone_number_id: "1064550806750058" },
              messages: [{ id: "wamid.incoming-1", type: "text" }],
            },
          }, {
            value: {
              metadata: { phone_number_id: "1064550806750058" },
              statuses: [{ id: "wamid.outgoing-1", status: "delivered" }],
            },
          }],
        }],
      }),
    },
  };

  await createMessageHandler({
    channel,
    logger,
    state: createWorkerState(),
    forward: () =>
      Promise.resolve({ outcome: "success", status: 200, attempts: 1 }),
  })(message(event));

  assert.deepEqual(infoLogs, [{
    message: "WhatsApp webhook event received from queue",
    fields: {
      event_id: webhookEvent.event_id,
      integration_key: "psdf",
      phone_number_ids: ["1064550806750058"],
      messages_count: 1,
      statuses_count: 1,
      message_types: ["text"],
      message_wamids: ["wamid.incoming-1"],
    },
  }]);
  assert.equal(JSON.stringify(infoLogs).includes("whatsapp_business_account"), false);
  assert.equal(JSON.stringify(infoLogs).includes("sha256="), false);
});

test("stores the untouched queue payload before parsing and forwarding", async () => {
  const { channel, calls } = channelMock();
  const rawPayload = `${JSON.stringify(replyEvent)}\n`;
  const order: string[] = [];
  let storedPayload = "";

  await createMessageHandler({
    channel,
    logger: silentLogger,
    state: createWorkerState(),
    storeRawEvent: (payload) => {
      order.push("stored");
      storedPayload = payload;
      return Promise.resolve();
    },
    forward: () => {
      order.push("forwarded");
      return Promise.resolve({ outcome: "success", status: 200, attempts: 1 });
    },
  })(message(rawPayload));

  assert.equal(storedPayload, rawPayload);
  assert.deepEqual(order, ["stored", "forwarded"]);
  assert.equal(calls.ack, 1);
});

test("requeues without forwarding when raw Supabase storage fails", async () => {
  const { channel, calls } = channelMock();
  let forwarded = false;

  await createMessageHandler({
    channel,
    logger: silentLogger,
    state: createWorkerState(),
    storeRawEvent: () => Promise.reject(new Error("database unavailable")),
    forward: () => {
      forwarded = true;
      return Promise.resolve({ outcome: "success", status: 200, attempts: 1 });
    },
  })(message(replyEvent));

  assert.equal(forwarded, false);
  assert.equal(calls.ack, 0);
  assert.equal(calls.nack, 1);
});
