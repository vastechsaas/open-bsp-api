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
WORKER_EVENT_TYPES=whatsapp_webhook,chatbot_reply,chatbot_handoff
```

The ingress remains single-active-consumer and routes original bytes through
confirmed publications into durable `.messages` and `.statuses` queues. Only
strictly status-only sent/delivered/read webhooks use the status lane. Mixed and
unknown webhooks stay in the message lane. No signed Meta body is rewritten.

```text
WORKER_MESSAGE_CONCURRENCY=4
WORKER_STATUS_CONCURRENCY=2
WORKER_MODE=parallel
OPENBSP_EDGE_REGION=ap-northeast-1
```

Set the region only for the intended project (Main is Tokyo); omit it to retain
automatic routing. Message/lifecycle work is serialized per customer. Status
updates serialize only identical message/status fields; the existing database
trigger atomically merges different status fields without erasing content. Known
local reply writes delay status scheduling without holding a processing slot,
for at most ten seconds. This is only a local optimization: the handler always
checks the durable original, including after restart or timeout. After a
successful verified status update, exact signed payload duplicates with the same
tenant credentials may reuse its confirmation for sixty seconds. This bounded
cache never handles messages/lifecycle work; every raw envelope is still stored
and a restart or cache miss uses the normal authenticated handler.
Multi-customer batches reserve all their keys atomically; unfamiliar events use
a tenant barrier. No new producer contract or database migration is required.

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
- `GET /readyz` requires ingress and both lane consumers. It includes per-lane
  active/pending counts and global in-flight/retry totals.
- HTTP and raw storage have ten-second timeouts. Network errors, HTTP 429 and
  HTTP 5xx retry durably after 5, 15, 30, 60 and 120 seconds, then move to the
  DLQ. There are no sleeping HTTP retries holding a processing slot.
- A message is acknowledged only after Edge Function success or confirmed DLQ
  publication.
- On `SIGTERM`/`SIGINT`, consumption stops, unstarted reservations remain
  unacknowledged, and active tasks drain for up to 45 seconds. Configure Docker
  `stop_grace_period: 55s`; unfinished work is redelivered with its stable ID.
- Logs contain correlation metadata only. Payloads, signatures and credentials
  are redacted.

New DLQ records retain the original envelope bytes; failure details are AMQP
headers. Legacy records may wrap them under `event`. Republish the original with
the same event ID and WAMID after fixing the cause; never blindly replay
customer events. Raw-event persistence is idempotent by payload hash.

## Main rollout / rollback

See the
[Main latency implementation and acceptance record](ops/MAIN-WORKER-LATENCY.md)
for benchmark results, accepted limitations, deployed versus candidate versions,
private backup locations and remaining verification work.

Use an isolated integration/number and unique ingress/routing/DLQ names for the
canary. Deploy the compatible `whatsapp-webhook` handler before the new worker:
authenticated `X-OpenBSP-Status-Only: 1` requests UPDATE existing messages only,
and retry when the original is absent. Existing callers are unchanged.

Back up the environment/Compose files with restrictive permissions and retain
the old image. Do not overlap old and new live workers: a legacy consumer can
otherwise receive ingress events ahead of the router. Stop the old worker, then
start the new one against the same ingress. Never purge queues.

Rollback uses this image with `WORKER_MODE=serial`, which drains ingress, both
lanes and their retries with one global processing slot. Per-lane retry queues
must be empty before restoring an older image that cannot consume these lanes.
Keep the compatible handler while draining. A rollback does not modify
histories, ownership, Node configuration or Meta webhooks.
