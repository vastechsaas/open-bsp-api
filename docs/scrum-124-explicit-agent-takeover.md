# SCRUM-124: Support requests and explicit takeover

Support requests route to the handoff node's existing queue/agent while Node
keeps bot ownership. Assignment and opening a chat never transfer control. The
first request retains its original source, reason and target; another escalation
cannot switch queues or duplicate its acknowledgment.

The waiting acknowledgment includes the configured text and explains that the
chatbot remains available. No extra menu is automatically sent. The branch ends,
so the next ordinary message begins a fresh active flow. `M` still opens the
main menu; `C` ends only the bot journey and explains that support is pending.
Previously sent buttons/lists remain usable until takeover invalidates them.

## Ownership and interfaces

- Conversation mapping JSON `support_request` is independent of `human_owned`.
- `POST chatbot-management/conversations/:id/takeover` requires organization ID,
  stable request ID, observed customer WAMID and expected ownership revision.
  The accepted human actor is derived server-side, never supplied by React.
- The assigned agent, an eligible queue agent claiming an unassigned chat, or an
  existing Owner/Admin/Supervisor can reserve takeover. A managerial override
  retains the original support queue in metadata, even if active assignment
  leaves that queue to satisfy existing assignment constraints.
- Reservation freezes assignment and customer replies, not Node execution. Only
  acknowledged Node ownership enables human sends. Private notes remain
  available under existing access rules.
- Node uses its existing contact transaction lock. Unsent bot work is cancelled,
  sessions cleared and menu generation invalidated. In-flight/ambiguous sends
  must finish or be reconciled before takeover succeeds.
- The takeover notification is a durable, revision-bound control dispatch. Its
  failure cannot undo ownership or lose the original request.
- Resolve & close and manager-only Return to chatbot retain their existing
  permissions, new-message checks and same-thread history behavior.

Queue handoffs accept optional `mode: support_requested` and `support_request`.
Missing mode retains legacy immediate handoff. Lifecycle events carry support
metadata and monotonic ownership revisions; stale events cannot restore an old
owner. Routing has its own deduplicated receipt, independent of notification
delivery and tolerant of a newer waiting snapshot arriving first.

## Disabled-by-default rollout

Backend secrets (in addition to the existing lifecycle/bridge configuration):

```text
NODE_EXPLICIT_TAKEOVER_ENABLED=false
NODE_EXPLICIT_TAKEOVER_ORGANIZATIONS=
```

Node environment:

```text
EXPLICIT_TAKEOVER_TENANTS=
```

Allowlist only one isolated staging organization UUID and its numeric Node
company ID after compatible backend, queue worker, UI and Node are deployed.
Both existing lifecycle flags must also permit that tenant. No frontend secret,
Meta webhook switch, PHP change, new ticket table or flow restructuring is
needed.

Before a deployment-triggering staging merge, back up staging project
`acifbsuxmpdtlhbsvhlj`, including schema, data, auth and storage metadata.
Confirm the target explicitly: Main is `buvjopvpkgvzhykwsxnk`, not staging. Back
up Oracle Node PostgreSQL and retain the current API/worker image before
applying Node's additive migration. Never print access tokens or copy them into
this guide.

## Verification and approval

Exercise waiting requests, repeated escalation, earlier menus, M/C, claim races,
human-send gating, unknown sends, delayed events, Node outages, request retries,
notification failures, resolve/message races and a later escalation. Test
assigned-agent, queue-member, managerial and cross-tenant boundaries.

Main rollout and DKR enablement require explicit approval after staging passes.
Flags remain off while deployment or verification is incomplete.

## Local verification and delivery gates (2026-10-04)

- New support/takeover database tests: 28 assertions passed. Existing
  conversation-lifecycle regression: 27 assertions passed.
- Queue integration worker: 31 tests, lint and build passed.
- Shared chatbot Deno tests: 100 passed, including durable takeover processing
  and timeout reconciliation.
- Frontend: 280 tests, generated-type synchronization, lint, TypeScript and
  production build passed. Existing lint warnings remain.
- Node: 100 tests across all suites passed, including seven explicit-takeover
  integration tests. Build, worker restart and PostgreSQL-outage checks passed
  against isolated local services.
- Full backend validation completed formatting, lint, type checks, plugin and
  voice-service checks, but the complete database suite did not pass. Existing
  `agent_role.sql` and `supervisor_role.sql` tests fail because this local
  database lacks the Vault edge-function URL/token. The existing platform
  tenant-summary test also fails its billing fixture: the local database has no
  default billing plan to initialize the fixture subscription. These files and
  the billing/dispatcher implementation are unchanged by SCRUM-124. This is not
  a full-backend-suite pass.

Two generated OpenBSP migrations must be applied in order. The first was already
applied locally when tests exposed a routing/event-ordering correction; the
second is a generated, function-only forward correction. No deployed migration
was rewritten. Both are unreleased and neither has been applied to staging or
Main. Generated types were regenerated/synchronized only once.

Oracle Node backup is verified at
`/opt/chatbots/node-engine/backups/scrum124-20261004/node-postgres.dump`. The
retained API/worker image is `node-chatbot-engine:scrum124-rollback`. No Oracle
application deployment/restart or feature enablement was performed.

Staging project `acifbsuxmpdtlhbsvhlj` is unavailable to the current CLI
account; Main remains linked. A fresh staging backup, compatible staging
deployment and isolated end-to-end verification are outstanding. Do not bypass
this gate with a Main migration or deployment.

## Safe rollback

1. Prevent new support requests and takeover actions from entering, while
   keeping the current runtime running. Do not merely clear the feature flag.
2. Reconcile every outstanding OpenBSP conversation operation through its stable
   request ID and current Node snapshot. If Node is unreachable, keep replies
   blocked and postpone rollback; never guess whether takeover committed.
3. With new ingress/actions stopped and pending operations reconciled, run
   Node's operator-only command for each affected company:

   ```text
   npm run prepare:support-rollback -- <company-id> --confirm-pending-operations-reconciled
   ```

   It transactionally pauses remaining waiting requests, cancels unsent work,
   invalidates menus and emits revisioned legacy-compatible human handoffs with
   their original targets. Ambiguous sends must be reconciled first. Re-running
   is safe; already paused conversations are not processed twice.
4. Wait for outbox delivery and verify OpenBSP reflects human ownership,
   original routing and no pending operations. Only then restore the previous
   image and disable the new feature. Keep additive database fields in place.
5. Existing human-owned requests remain paused for support; never resume them or
   change the number's engine automatically during rollback.
