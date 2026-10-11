# Shared support acknowledgment

## Configuration

Owners/admins edit **Settings → Business hours → Support messages**. The new
support-request acknowledgment is stored in
`organizations.extra.business_hours.handoff_message`. Queue selection stays in
the builder. A nonempty `assign_agent.config.acknowledgment_text` remains a
branch override; clearing it deliberately restores the Settings default. No
existing flow or custom text is rewritten, published or reactivated.

For enrolled Node tenants, OpenBSP selects one message when the durable handoff
event is processed:

1. Outside enabled business hours: the outside-hours message.
2. Open hours, no eligible fresh agent presence: the no-agents message.
3. Otherwise: the existing branch override, then the organization default, then
   the built-in neutral acknowledgment.

Settings changes apply to subsequent handoff requests without republishing.
Messages are plain text; shared Settings wording does not interpolate flow
variables. Node resolves variables in existing branch overrides as before. An
already queued acknowledgment keeps its original wording.

## Reliability and compatibility

The Node worker emits an optional `acknowledgment` object on `chatbot_handoff`
events instead of sending its own waiting acknowledgment. The integration worker
forwards it using existing tenant authentication. Routing, the selected outgoing
message and the event receipt commit together in OpenBSP. Stable event IDs
deduplicate delivery; a later request while waiting has a separate event
referencing the first routing receipt. Out-of-order events retry. Repeat
requests never clear assignment or change the original queue. Stale/handled
requests, blocked contacts, suspended organizations and expired 24-hour service
windows do not originate a new acknowledgment.

The acknowledgment uses the existing OpenBSP outgoing-message dispatcher, not
Node's message outbox. There is no second availability notice for managed
events. Bot menus remain usable until confirmed takeover. Existing non-enrolled
Node tenants and PHP/native acknowledgment behavior remain unchanged.

## Deployment

Feature branches: `codex/shared-handoff-messages-backend`,
`codex/shared-handoff-messages-ui`, `codex/shared-handoff-messages-node`. This
feature is disabled by default.

1. Back up the target database and deploy the generated backend migration and
   `chatbot-handoff-webhook`. The migration changes function signatures with
   optional parameters, not conversation or flow data. Existing callers remain
   compatible. The generated diff's unrelated table revokes were removed;
   schema-source function ACLs were reapplied because the diff omitted them.
2. Deploy the compatible integration worker contract and Node API/worker.
3. Deploy the UI.
4. Only after all components are compatible, add `"support_messages":"settings"`
   to the enrolled company entry in `OPENBSP_TENANT_ROUTES`. Preserve its
   existing integration key and app ID. This requires the existing
   explicit-takeover/lifecycle tenant configuration and AMQP publishing. Do not
   enable the route on an old queue handler.
5. Verify a disposable tenant: default, existing override, outside hours,
   open/no agent, repeat request, duplicate delivery and takeover. Confirm one
   customer message per request in WhatsApp and Chat Center.

For rollback, stop new enrollment by removing the route option, retain the
compatible queue handler and migration while managed events drain, and retain
existing message/receipt records. Never purge queues or send a second
acknowledgment to compensate for an ambiguous send.

No Main/Oracle deployment or live DKR flow edit is part of the feature-branch
implementation.

## Validation

- Backend quick and full validation passed; all 1,023 database assertions passed
  across 48 files, including 20 focused shared-message assertions.
- Integration worker build/lint and all 35 tests passed.
- Node TypeScript/Prisma build, 9 boundary/broker tests, 57 core assertions and
  9 explicit-takeover integration tests passed against dedicated local services.
- Frontend focused Business Hours tests passed (20); full validation is recorded
  in the feature delivery summary.
- No live customer message, handoff, takeover or DKR flow change was performed.
