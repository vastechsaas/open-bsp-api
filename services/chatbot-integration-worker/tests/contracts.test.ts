import assert from "node:assert/strict";
import test from "node:test";
import { integrationEventSchema } from "../src/contracts.js";
import { account, replyEvent, webhookEvent } from "./fixtures.js";

test("preserves optional support-request mode without changing legacy handoff", () => {
  const target = { routing_queue_id: "00000000-0000-4000-8000-000000000124" };
  const request = {
    id: "00000000-0000-4000-8000-000000000125",
    status: "waiting",
    target,
    source_wamid: "wamid.incoming-1",
    requested_at: "2026-10-04T12:00:00Z",
    reason: "Refund request",
  };
  const event = {
    ...replyEvent,
    event_type: "chatbot_handoff",
    payload: {
      phone_number_id: account.phone_number_id,
      recipient: "923000000001",
      source_wamid: request.source_wamid,
      node_conversation_id: "124",
      target,
      revision: "1",
    },
  };
  assert.equal(integrationEventSchema.safeParse(event).success, true);
  const parsed = integrationEventSchema.parse({
    ...event,
    payload: {
      ...event.payload,
      mode: "support_requested",
      support_request: request,
    },
  });
  assert.equal(parsed.event_type, "chatbot_handoff");
  if (parsed.event_type === "chatbot_handoff") {
    assert.deepEqual(parsed.payload.support_request, request);
  }
  assert.equal(
    integrationEventSchema.safeParse({
      ...event,
      payload: { ...event.payload, mode: "unknown" },
    }).success,
    false,
  );
  assert.equal(
    integrationEventSchema.safeParse({
      ...event,
      payload: {
        ...event.payload,
        support_request: { ...request, credential: "must not leak" },
      },
    }).success,
    false,
  );
});

test("accepts the two version-one event contracts", () => {
  assert.equal(
    integrationEventSchema.parse(webhookEvent).event_type,
    "whatsapp_webhook",
  );
  assert.equal(
    integrationEventSchema.parse(replyEvent).event_type,
    "chatbot_reply",
  );
});

test("accepts monotonic lifecycle context, rejects malformed revisions and secret-bearing payloads", () => {
  const event = {
    ...replyEvent,
    event_type: "chatbot_conversation_lifecycle",
    payload: {
      phone_number_id: account.phone_number_id,
      recipient: "923000000001",
      node_conversation_id: "117",
      revision: "9007199254740993",
      state: "closed",
      last_inbound_wamid: "wamid.customer-1",
    },
  };
  assert.equal(integrationEventSchema.safeParse(event).success, true);
  assert.equal(
    integrationEventSchema.safeParse({
      ...event,
      payload: { ...event.payload, revision: "-1" },
    }).success,
    false,
  );
  assert.equal(
    integrationEventSchema.safeParse({
      ...event,
      payload: { ...event.payload, serviceCredential: "never leak" },
    }).success,
    false,
  );
});

test("rejects unsupported versions and missing outgoing WAMIDs", () => {
  assert.equal(
    integrationEventSchema.safeParse({ ...replyEvent, version: 2 }).success,
    false,
  );
  const payload = { ...replyEvent.payload, wamid: undefined };
  assert.equal(
    integrationEventSchema.safeParse({ ...replyEvent, payload }).success,
    false,
  );
});

test("rejects modified webhook signatures and non-JSON raw bodies", () => {
  assert.equal(
    integrationEventSchema.safeParse({
      ...webhookEvent,
      payload: { ...webhookEvent.payload, x_hub_signature_256: "invalid" },
    }).success,
    false,
  );
  assert.equal(
    integrationEventSchema.safeParse({
      ...webhookEvent,
      payload: { ...webhookEvent.payload, raw_body: "not-json" },
    }).success,
    false,
  );
});
