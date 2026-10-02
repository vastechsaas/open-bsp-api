import assert from "node:assert/strict";
import test from "node:test";
import { integrationEventSchema } from "../src/contracts.js";
import { account, replyEvent, webhookEvent } from "./fixtures.js";

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
