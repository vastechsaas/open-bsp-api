import type { IntegrationEvent } from "../src/contracts.js";

export const account = {
  phone_number_id: "15551234567",
  meta_app_id: "123456789012345",
  chatbot: { key: "psdf", name: "PSDF" },
  openbsp_api_key: "openbsp-secret",
};

export const webhookEvent: IntegrationEvent = {
  version: 1,
  event_id: "00000000-0000-4000-8000-000000000001",
  event_type: "whatsapp_webhook",
  integration_key: "psdf",
  occurred_at: "2026-08-23T10:00:00Z",
  payload: {
    raw_body: '{"object":"whatsapp_business_account","entry":[]}',
    x_hub_signature_256:
      "sha256=0000000000000000000000000000000000000000000000000000000000000000",
    app_id: "123456789012345",
  },
};

export const replyEvent: IntegrationEvent = {
  version: 1,
  event_id: "11111111-1111-4111-8111-111111111111",
  event_type: "chatbot_reply",
  integration_key: "psdf",
  occurred_at: "2026-08-23T10:00:01Z",
  payload: {
    phone_number_id: "15551234567",
    recipient: "923001234567",
    wamid: "wamid.outgoing-1",
    sent_at: "2026-08-23T10:00:01Z",
    reply_to_wamid: "wamid.incoming-1",
    message: { type: "text", text: { body: "Hello" } },
  },
};

export const silentLogger = {
  debug() {},
  info() {},
  warn() {},
  error() {},
};
