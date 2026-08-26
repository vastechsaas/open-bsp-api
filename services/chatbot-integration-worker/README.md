# Chatbot integration worker

Long-running CloudAMQP consumer that reliably forwards PHP chatbot events to the
existing OpenBSP Edge Functions. For development diagnostics, it stores the
exact queue payload in Supabase before parsing or forwarding it.

## Contract

PHP publishes persistent JSON messages to exchange `openbsp.integration` with
routing key `chatbot.event.v1`. The worker declares:

- main queue `openbsp.chatbot.events.v1` with single-active-consumer;
- dead-letter exchange `openbsp.integration.dlx`;
- dead-letter queue `openbsp.chatbot.events.dlq.v1`.

Every event uses this envelope:

```json
{
  "version": 1,
  "event_id": "stable UUID reused for every publish retry",
  "event_type": "whatsapp_webhook or chatbot_reply",
  "integration_key": "psdf",
  "occurred_at": "2026-08-23T10:00:00Z",
  "payload": {}
}
```

For `whatsapp_webhook`, `payload` contains the exact `raw_body` received from
Meta, its unchanged `x_hub_signature_256`, and the real `app_id`. Do not decode
and re-encode the raw body before publishing.

For `chatbot_reply`, `payload` matches the existing chatbot reply contract but
omits `chatbot`; the worker adds the configured identity. The outgoing `wamid`
returned by Meta is mandatory. `reply_to_wamid` is optional.

Queue messages must not contain OpenBSP API keys, CloudAMQP credentials, Meta
secrets, or access tokens.

## Run and test

```powershell
npm ci
npm test
npm run lint
npm run build
docker build -t openbsp-chatbot-worker .
docker run --env-file .env -p 8080:8080 openbsp-chatbot-worker
```

Copy `.env.example` to `.env` and supply real secrets outside source control.
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are used to insert the untouched
queue message into `chatbot_integration_raw_events` before processing.
`OPENBSP_ACCOUNT_CONFIG_JSON` maps the public `integration_key` to its expected
Phone Number ID, Meta App ID, chatbot identity and tenant API key.

The queue topology is configurable while retaining safe ordered defaults:

```text
RABBITMQ_EXCHANGE=openbsp.integration
RABBITMQ_QUEUE=openbsp.chatbot.events.v1
RABBITMQ_ROUTING_KEY=chatbot.event.v1
RABBITMQ_DLX=openbsp.integration.dlx
RABBITMQ_DLQ=openbsp.chatbot.events.dlq.v1
RABBITMQ_DLQ_ROUTING_KEY=chatbot.event.dlq.v1
WORKER_EVENT_TYPES=whatsapp_webhook,chatbot_reply
```

Keep both event types on the default queue for V1. A future deployment can run
separate worker instances with different queue/routing-key values and one event
type each, but only after an ordering safeguard prevents replies from overtaking
their customer messages.

Publish a reviewed fixture:

```powershell
$env:CLOUDAMQP_URL = "amqps://..."
npm run publish:fixture -- fixtures/whatsapp-webhook.json
npm run publish:fixture -- fixtures/chatbot-reply.json
```

Replace every placeholder WAMID, signature, account identifier and timestamp
with values from the same real conversation before a staging smoke test.

For Postman-based producer testing, import both files from `postman/`, select
the imported environment, fill its placeholders, start the worker, then run the
incoming request before the chatbot-reply request. The malformed request is a
DLQ-only test.

Before queue testing, the `OpenBSP-Direct-WhatsApp-Webhook` collection can send
the exact Meta body directly to the Edge Function. It generates the matching
signature from a local Postman secret. A successful persistence log confirms the
payload independently of RabbitMQ and the worker.

## Operations

- `GET /healthz` proves the process is alive.
- `GET /readyz` returns 200 only while RabbitMQ consumption is active.
- Delivery is one event at a time. Network errors, HTTP 429 and HTTP 5xx retry
  twice after 1 and 5 seconds. Other failures move to the DLQ.
- A message is acknowledged only after Edge Function success or confirmed DLQ
  publication.
- On `SIGTERM`/`SIGINT`, the worker stops accepting new deliveries and closes
  its RabbitMQ and HTTP resources.
- Logs contain correlation metadata only. Payloads, signatures and credentials
  are redacted.

For DLQ recovery, correct the payload or configuration, republish the original
`event` with the same `event_id` and WAMID to the main exchange, then remove the
DLQ record.
