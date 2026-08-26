import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig } from "../src/config.js";

const baseEnvironment = {
  CLOUDAMQP_URL: "amqps://guest:guest@example.com/vhost",
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "service-role-secret",
  OPENBSP_FUNCTIONS_BASE_URL: "https://example.supabase.co/functions/v1",
  OPENBSP_ACCOUNT_CONFIG_JSON: JSON.stringify({
    psdf: {
      phone_number_id: "123456789",
      meta_app_id: "987654321",
      chatbot: { key: "psdf", name: "PSDF" },
      openbsp_api_key: "test-secret",
    },
  }),
};

test("uses the single ordered queue defaults", () => {
  const config = loadConfig(baseEnvironment);
  assert.equal(config.topology.queue, "openbsp.chatbot.events.v1");
  assert.deepEqual([...config.acceptedEventTypes], [
    "whatsapp_webhook",
    "chatbot_reply",
  ]);
});

test("allows an instance-specific queue and event type", () => {
  const config = loadConfig({
    ...baseEnvironment,
    RABBITMQ_QUEUE: "openbsp.chatbot.incoming.v1",
    RABBITMQ_ROUTING_KEY: "chatbot.incoming.v1",
    WORKER_EVENT_TYPES: "whatsapp_webhook",
  });
  assert.equal(config.topology.queue, "openbsp.chatbot.incoming.v1");
  assert.equal(config.topology.routingKey, "chatbot.incoming.v1");
  assert.deepEqual([...config.acceptedEventTypes], ["whatsapp_webhook"]);
});

test("rejects unsupported or empty event-type configuration", () => {
  assert.throws(
    () => loadConfig({ ...baseEnvironment, WORKER_EVENT_TYPES: "unknown" }),
    /unsupported event type/,
  );
  assert.throws(
    () => loadConfig({ ...baseEnvironment, WORKER_EVENT_TYPES: "" }),
  );
});
