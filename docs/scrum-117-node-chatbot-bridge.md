# SCRUM-117: Node chatbot bridge

Chat Center remains the editor. Activation translates a published definition
into an immutable Node version. Editing and publishing alone do not synchronize
it. Existing PHP tenants and the native engine remain unchanged by default.

## Enable on staging after deploying Node

1. Deploy the Node branch's API and worker, PostgreSQL migration, Redis and
   RabbitMQ.
2. Bootstrap a dedicated Node tenant and WhatsApp number with its existing
   commands.
3. Deploy the updated chatbot integration worker (handoff support). If its
   existing environment explicitly sets `WORKER_EVENT_TYPES`, add
   `chatbot_handoff`.
4. Configure backend-only `NODE_CHATBOT_CONNECTIONS` as JSON:
   `{"<organization UUID>:<phone number ID>":{"url":"https://<node-host>","company_id":"<numeric ID>","credential":"<tenant service credential>"}}`.
5. Set `NODE_CHATBOT_BRIDGE_ENABLED=true` only after services are reachable.
6. Activate a published Chat Center flow using the Node engine on a disposable
   staging number. Verify replies, handoff, explicit resume and deactivation.

Configuration remains backend-only. Never put tenant credentials in Vite
variables or commit them. Archived organizations queue suspension/restoration
operations; monitor synchronization failures during remote outages.

## Reliability and rollback

Operations are stored before remote calls. Each phase uses a stable request ID;
ambiguous acknowledgments are looked up before retry. Five submission attempts
are allowed per phase; manual Retry preserves the request ID.

One engine is selected per number. Transitioning, disabled and Node-managed
numbers suppress native execution. Disable Node first when rolling back; native
activation is a separate explicit action. Deactivation does not disconnect Meta.

Node integration events use the existing reply/customer contracts plus
`chatbot_handoff`. Missing customer conversation creation returns a retryable
failure; the integration worker's dead-letter queue must be monitored and
replayed after its bounded retries. Closing a conversation does not resume the
chatbot.

The periodic bridge worker uses the existing Vault edge-function URL/token. It
must be deployed alongside `chatbot-management` and `chatbot-handoff-webhook`.
No Node deployment workflow or production webhook switch is introduced here.
