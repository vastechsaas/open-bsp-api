import assert from "node:assert/strict";
import test from "node:test";
import type { ConfirmChannel, ConsumeMessage } from "amqplib";
import { createWorkerState } from "../src/state.js";
import { createMessageHandler } from "../src/worker.js";
import { replyEvent, silentLogger } from "./fixtures.js";

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
