import assert from "node:assert/strict";
import test from "node:test";
import { integrationEventSchema } from "../src/contracts.js";
import { replyEvent, webhookEvent } from "./fixtures.js";

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
