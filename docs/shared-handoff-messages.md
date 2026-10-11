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
4. Drain existing legacy handoff acknowledgments for the test tenant before
   enrollment; never rewrite already queued events. After all components are
   compatible, add `"support_messages":"settings"` to the enrolled company entry
   in `OPENBSP_TENANT_ROUTES`. Preserve its existing integration key and app ID.
   This requires the existing explicit-takeover/lifecycle tenant configuration
   and AMQP publishing. Do not enable the route on an old queue handler.
5. Verify a disposable tenant: default, existing override, outside hours,
   open/no agent, repeat request, duplicate delivery and takeover. Confirm one
   customer message per request in WhatsApp and Chat Center.

For rollback, stop new enrollment by removing the route option, retain the
compatible queue handler and migration while managed events drain, and retain
existing message/receipt records. Never purge queues or send a second
acknowledgment to compensate for an ambiguous send.

No live DKR flow edit is required for this feature.

## Release — 2026-10-11

Released with explicit approval to staging and Main:

- Backend staging: `7a10002`; Main implementation: `665a2ea`.
- Frontend staging: `b43eb5c`; Main: `561939e`.
- Node Main and Oracle API/worker: `39c8a99`.
- Main integration worker: `openbsp-main-chatbot-worker:665a2ea`, built from
  Main with the existing parallel lanes, regional routing and latency fixes.
- Main migration `20261011150827_shared_handoff_messages.sql` applied and
  `chatbot-handoff-webhook` deployed. Supabase Git integration reported success
  for both Main and staging; direct staging CLI inspection is unavailable to the
  current account (HTTP 403).
- Main schema/data/role backups are stored privately under
  `.codex/backups/shared-handoff-messages-20261011/` on the deployment
  workstation. Oracle's Node database backup and previous configuration are
  under `/opt/chatbots/node-engine/backups/shared-handoff-20261011/`; its
  restore inventory was checked. The worker configuration is backed up under its
  corresponding `backups/shared-handoff-20261011/` directory.
- Previous images retained as
  `node-chatbot-engine:rollback-shared-handoff-20261011` and
  `openbsp-main-chatbot-worker:rollback-shared-handoff-20261011`.
- DKR (Node company 1) is enrolled with `support_messages: "settings"`. Other
  tenant routes are unchanged. Node processing was briefly held at the mode
  boundary; there were zero undelivered legacy handoff events and zero
  unresolved legacy waiting-acknowledgment dispatches. No queue was purged.
- Node HTTPS readiness and Main worker readiness passed. Worker readiness
  reported connected, consuming, parallel lanes ready and no pending work.
- Vercel production deployments succeeded for both frontend environments. The
  shared-message labels were verified on `socialconnect.vastech.biz` and
  `vistagalaxy.vastech.biz` with cache-bypassed locale requests.
- Main-focused release checks passed: 20 database assertions, 51 integration
  worker tests/build, 20 UI tests, generated DB type synchronization and the
  Main production UI build. The Main UI cherry-pick retained its existing
  inspector instead of importing staging-only field-diagnostic components.

No customer messages, conversation actions, flow edits, publishing or
reactivation were performed for release verification. A real WhatsApp handoff
test is still required to verify the complete customer-facing path.

## Validation

- Backend quick and full validation passed; all 1,023 database assertions passed
  across 48 files, including 20 focused shared-message assertions.
- Integration worker build/lint and all 35 tests passed.
- Node TypeScript/Prisma build, 9 boundary/broker tests, 57 core assertions and
  9 explicit-takeover integration tests passed against dedicated local services.
- Frontend focused Business Hours tests passed (20). Full frontend validation
  passed: 371 tests, generated-type synchronization, formatting/lint, TypeScript
  and the production build.
- No live customer message, handoff, takeover or DKR flow change was performed.
