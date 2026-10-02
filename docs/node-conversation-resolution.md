# SCRUM-123: Resolve & close Node support chats

An assigned agent or an existing Owner/Admin/Supervisor resolves human support.
The conversation remains open and human-owned while synchronization is pending;
customer replies are disabled during that transition. Private notes remain
available. Node confirmation closes the same thread without sending a customer
message. Every subsequent customer message, including “Thanks”, reopens its
history and starts the active bot fresh. Later escalations use their configured
queue.

## Boundaries

- Conversation operations never change the number's selected engine.
- Contact locking, observed inbound WAMID and ownership revision protect closing
  against new messages. Pending/ambiguous human or bot sends prevent closure.
- Node records immutable request results and durable, revisioned lifecycle
  events. OpenBSP reconciles current ownership before accepting an older
  acknowledgment.
- Old handoff/menu generations cannot resurrect a previous journey.
- Return to chatbot remains an explicit manager-only overflow action, not
  resolution.
- PHP/native behavior, business hours and flow definitions are unchanged.

## Disabled-by-default rollout

Backend settings (server-side only):

```text
NODE_CONVERSATION_LIFECYCLE_ENABLED=false
NODE_CONVERSATION_LIFECYCLE_ORGANIZATIONS=
```

To test, set enabled to `true` and allowlist ONLY the disposable staging
organization UUID. Node's `CONVERSATION_LIFECYCLE_TENANTS` accepts the
corresponding numeric company ID; empty means disabled. Avoid `*` during
rollout. The existing bridge connection, credentials, tenant routing and API-key
authentication remain required.

The integration worker must accept `chatbot_conversation_lifecycle` alongside
`whatsapp_webhook`, `chatbot_reply` and `chatbot_handoff`. Existing explicit
`WORKER_EVENT_TYPES` settings must be updated; code defaults alone do not update
an already configured worker. Deploy the lifecycle webhook with JWT verification
disabled because it uses the existing tenant API-key authentication.

## Deployment gates

1. Confirm staging project `acifbsuxmpdtlhbsvhlj`; the currently linked Main
   project `buvjopvpkgvzhykwsxnk` must NOT receive this migration.
2. Back up staging schema/data/auth/storage before a staging push that triggers
   deployment. Do not deploy without verified staging access and its backup.
3. Back up Oracle Node PostgreSQL and retain the previous application image.
4. Apply additive migrations, deploy backend/worker before UI, with flags off.
5. Allowlist an isolated test tenant and exercise close-before/after-message,
   duplicate requests, outages/restarts, old menus, later handoff and role
   boundaries.
6. Enable DKR only after those checks; Main requires separate staging approval.

The existing Oracle backup is:
`/opt/chatbots/node-engine/backups/scrum123-20261001/node-postgres.dump`. It
passed `pg_restore --list`; SHA-256 is
`914fca5ffac5826a8b173cc646f9bd81605fcf8ff2d24fb550b6acfe09ae86fc`. Previous
image: `node-chatbot-engine:scrum123-rollback` (original `311b75c`).

## Failure and rollback

Use the same durable request ID to reconcile uncertain outcomes. A failed
request can be retried only after current permissions, ownership, observed
inbound and pending sends are checked again. Do not claim rollback when Node is
unreachable. An outage stays “Closing—sync pending”; do not clear ownership
manually.

For rollback, disable new lifecycle actions, reconcile in-flight operations
first, then restore the retained application image. Leave additive schema in
place. Never resume paused bot sessions or switch engine selection
automatically.

## Implementation verification (2026-10-02)

- Backend lifecycle database regression: 27 assertions passed.
- Shared chatbot Deno tests: 85 passed; lifecycle processor tests: 4 passed.
- Integration worker: 30 tests, lint and build passed.
- Frontend: 266 tests, type synchronization, lint, TypeScript and build passed.
- Node: build, lifecycle/infrastructure/recovery/rules/outage and worker smoke
  checks passed. The original handoff mock and smoke-test timing failures were
  corrected and their affected suites rerun successfully.
- Full backend validation completed its formatter, lint, type checks, plugin and
  voice-service checks. The database suite did not pass: the existing local
  database has baseline ACL/Vault drift; a fresh isolated database additionally
  lacks the Auth service's complete schema and Vault root-key initialization.
  These are unresolved verification limitations, not a full-suite pass.

The original generated migration was already applied locally when review found
an atomic failed-request retry race. A second generated, function-only
corrective migration fixes it without editing the applied migration. Apply both
in order; the correction does not require another generated-type pass.

Feature branches are `scrum-123-resolve-close-backend`,
`scrum-123-resolve-close-ui` and `scrum-123-resolve-close-node`. Deployment
remains blocked until an account with staging project access is available for a
verified backup and isolated staging test. Do not bypass that gate by deploying
to the currently linked Main project.
