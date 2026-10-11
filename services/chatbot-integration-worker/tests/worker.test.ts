/* eslint-disable @typescript-eslint/require-await -- Async test doubles implement the production Promise interface. */
import assert from "node:assert/strict";
import test from "node:test";
import type { ConfirmChannel, ConsumeMessage, Options } from "amqplib";
import { createWorkerState } from "../src/state.js";
import { createIngressHandler, createMessageHandler } from "../src/worker.js";
import { defaultTopology } from "../src/topology.js";
import { replyEvent, silentLogger, webhookEvent } from "./fixtures.js";

function setup(body: unknown = replyEvent, retry = 0) {
  const incoming = {
    content: Buffer.from(
      typeof body === "string" ? body : JSON.stringify(body),
    ),
    properties: {
      messageId: replyEvent.event_id,
      headers: { "x-openbsp-retry": retry },
    },
  } as unknown as ConsumeMessage;
  const calls = {
    ack: 0,
    nack: 0,
    published: [] as Array<
      { queue: string; content: Buffer; properties?: Options.Publish }
    >,
  };
  const channel = {
    ack: () => {
      calls.ack++;
    },
    nack: () => {
      calls.nack++;
    },
  } as unknown as ConfirmChannel;
  const publish = (
    queue: string,
    content: Buffer,
    properties?: Options.Publish,
  ) => {
    assert.equal(calls.ack, 0);
    calls.published.push({ queue, content, properties });
    return Promise.resolve();
  };
  const state = createWorkerState();
  const options = {
    channel,
    publish,
    state,
    logger: silentLogger,
    forward: async () => ({
      outcome: "success" as const,
      status: 200,
      attempts: 1,
    }),
  };
  return { incoming, calls, options, state };
}

test("stores original raw bytes before forwarding and acknowledges success only", async () => {
  const { incoming, calls, options, state } = setup(
    `${JSON.stringify(replyEvent)}\n`,
  );
  const order: string[] = [];
  await createMessageHandler({
    ...options,
    storeRawEvent: async (raw) => {
      assert.equal(raw, incoming.content.toString());
      order.push("store");
    },
    forward: async () => {
      assert.equal(calls.ack, 0);
      order.push("forward");
      return { outcome: "success", status: 200, attempts: 1 };
    },
  })(incoming);
  assert.deepEqual(order, ["store", "forward"]);
  assert.equal(calls.ack, 1);
  assert.equal(state.inFlight, 0);
  assert.equal(state.processed, 1);
});

for (const status of [undefined, 429, 500, 503]) {
  test(`durable retry for ${status} frees the prerequisite lane`, async () => {
    const { incoming, calls, options } = setup();
    await createMessageHandler({
      ...options,
      forward: async () => ({
        outcome: "permanent_failure",
        reason: "pending",
        status,
        attempts: 1,
      }),
    })(incoming);
    assert.equal(
      calls.published[0]!.queue,
      "openbsp.chatbot.events.v1.messages.retry.1",
    );
    assert.equal(calls.published[0]!.content, incoming.content);
    assert.equal(
      (calls.published[0]!.properties?.headers as Record<string, unknown>)[
        "x-openbsp-retry"
      ],
      1,
    );
    assert.equal(calls.ack, 1);
  });
}
test("raw-store outages use bounded durable retry without forwarding", async () => {
  const { incoming, calls, options } = setup();
  await createMessageHandler({
    ...options,
    storeRawEvent: async () => {
      throw new Error("offline");
    },
    forward: async () => {
      throw new Error("must not run");
    },
  })(incoming);
  assert.equal(calls.published[0]!.queue.endsWith("messages.retry.1"), true);
  assert.equal(calls.ack, 1);
});
for (
  const [body, status, retry] of [["not json", 400, 0], [replyEvent, 401, 0], [
    replyEvent,
    503,
    5,
  ]] as const
) {
  test(`invalid/permanent/exhausted event goes to DLQ (${status}/${retry})`, async () => {
    const { incoming, calls, options } = setup(body, retry);
    await createMessageHandler({
      ...options,
      forward: async () => ({
        outcome: "permanent_failure",
        status,
        reason: "failure",
        attempts: 1,
      }),
    })(incoming);
    assert.equal(calls.published[0]!.queue, defaultTopology.deadLetterQueue);
    assert.equal(calls.published[0]!.content, incoming.content);
    assert.equal(calls.ack, 1);
  });
}
test("failed durable publication never acknowledges the original", async () => {
  const { incoming, calls, options } = setup("invalid");
  await createMessageHandler({
    ...options,
    publish: async () => {
      throw new Error("broker lost");
    },
  })(incoming);
  assert.equal(calls.ack, 0);
  assert.equal(calls.nack, 1);
});
test("ingress routes unchanged bytes only after confirmation", async () => {
  const { incoming, calls, options } = setup();
  await createIngressHandler({ ...options, topology: defaultTopology })(
    incoming,
  );
  assert.equal(calls.published[0]!.queue, `${defaultTopology.queue}.messages`);
  assert.equal(calls.published[0]!.content, incoming.content);
  assert.equal(calls.ack, 1);
});
test("disabled event is retained in DLQ", async () => {
  const { incoming, calls, options } = setup(replyEvent);
  await createMessageHandler({
    ...options,
    acceptedEventTypes: new Set(["whatsapp_webhook"]),
  })(incoming);
  assert.equal(calls.published[0]!.queue, defaultTopology.deadLetterQueue);
});
test("metrics contain no body/signature/customer identifiers", async () => {
  const { incoming, options } = setup(webhookEvent);
  const logs: unknown[] = [];
  await createMessageHandler({
    ...options,
    logger: {
      ...silentLogger,
      info: (_message, fields) => {
        logs.push(fields);
      },
    },
  })(incoming);
  assert.equal(JSON.stringify(logs).includes("sha256="), false);
  assert.equal(JSON.stringify(logs).includes("raw_body"), false);
  assert.equal(JSON.stringify(logs).includes("923001234567"), false);
});
