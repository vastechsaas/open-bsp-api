# SCRUM-127: reliable support conversation episodes

Jira: https://hureram8.atlassian.net/browse/SCRUM-127

## Behavior and boundaries

Confirmed closure is terminal for an enrolled Node conversation. Its assignment
and resolution attribution remain for existing history permissions. A new
inbound message creates exactly one successor under Node's contact transaction;
it starts the activated bot without inheriting the previous support target or
agent. Normal bot completion and C are not support resolution and do not create
episodes. Enrolled support requests pause execution while waiting for confirmed
takeover. Return to chatbot is a manager-only transfer, not closure.

Header and composer share an account/organization/conversation-scoped local
snapshot. A fresh confirmation is valid for 60 seconds; reconciliation is
asynchronous. Pending actions poll every two seconds, confirmed state every 20
seconds, and private Realtime/focus/reconnect invalidate the snapshot. Every
mutation still checks authorization, ownership, observed inbound and pending
sends. Only Node confirmation closes a thread. No automatic closing message is
sent.

Previous chats uses a security-invoker, RLS-preserving pagination RPC (10/25/50,
maximum 50) and separately paginated message queries (30, timestamp + ID
cursor). It never changes the active conversation or merges previous messages
into it.

## Queue protocol

Existing PHP envelopes are unchanged. Node adds optional episode context:
node_conversation_id, episode_number, previous_node_conversation_id. For signed
Meta bodies it sends a separate node_messages map keyed by WAMID. The
integration worker forwards this as an authenticated header, preserving exact
signed bytes. Node waits for its inbound transaction before forwarding context.
Outgoing statuses retain their original message/conversation identity.

OpenBSP resolves the explicit episode, not the latest matching telephone number.
Successors wait for their predecessor's confirmed closure. Missing dependencies
return retryable failures: the worker confirms a durable 30-second retry copy
before acknowledging, up to five delayed retries, then retains evidence in DLQ.
Replay a corrected DLQ through the original contract; never guess its
destination.

The recovery worker starts up to three operations concurrently, stops starting
work after 45 seconds, and its cron HTTP timeout is 55 seconds. Stable IDs and
revision fences remain authoritative after ambiguous network failures.

## Rollout gates (staging only)

Branches:

- scrum-127-reliable-support-backend
- scrum-127-reliable-support-ui
- scrum-127-reliable-support-node

1. Obtain access to staging acifbsuxmpdtlhbsvhlj. Do not relink or migrate Main
   buvjopvpkgvzhykwsxnk as a substitute. Back up staging schema/data and
   securely retain dumps (including auth/storage when relevant) before
   deployment.
2. Back up Oracle Node PostgreSQL and verify pg_restore --list. Retain the
   current application image, but label it incompatible with post-episode
   rollback.
3. Build and retain an episode-aware compatibility image from the new Node code
   before removing the old uniqueness constraint. Keep all new allowlists empty.
   This image is the rollback target once multiple conversations can exist.
4. Deploy backend migration/handlers and the compatible queue worker. Apply the
   Node migration while API/worker are stopped, then start compatible
   API/worker. Deploy the dependent UI only after these pass health checks.
5. Verify the isolated staging organization's existing Node binding, service
   credential, WABA/phone binding, tenant route and worker account
   configuration. The authenticated Node capabilities endpoint must advertise
   openbsp-conversation-episodes-v1, openbsp-conversation-lifecycle-v1 and
   openbsp-explicit-takeover-v1.
6. OpenBSP: NODE_CONVERSATION_EPISODES_ENABLED=true and
   NODE_CONVERSATION_EPISODE_ORGANIZATIONS=<isolated-staging-org-uuid>. Node:
   CONVERSATION_EPISODE_TENANTS=<isolated-company-id>, with matching
   CONVERSATION_LIFECYCLE_TENANTS and EXPLICIT_TAKEOVER_TENANTS allowlists.
   Existing bridge/lifecycle/takeover flags are still required.
7. Verify handoff, takeover, closure races, duplicate/out-of-order delivery,
   successor routing, Closed filter and authorized Previous chats with that
   disposable tenant. Main/DKR IDs must remain absent from every new allowlist.

No Main deployment, PHP change, Meta webhook change, DKR edit or automatic
tenant configuration is part of this rollout.

## Rollback

Pause new rollout enrollment and episode creation; keep episode-aware code and
queue routing operational. Existing mappings remain routable after the OpenBSP
rollout flag is disabled. Node refuses to reopen a resolved enrolled episode
when creation is paused; its input stays retryable/durable (monitor ingestion
DLQ and redrive after re-enabling). Active episodes can still complete safely.

Reconcile pending requests and ambiguous sends by stable IDs before any runtime
change. Restore only the retained multi-conversation-compatible image. Never
restore the old single-conversation runtime after dropping its unique
constraint. Leave the new schema and existing predecessor links intact. Do not
merge, move or split messages, restore database snapshots over live data, or
reopen Closed history as a rollback technique.

## Deployment access recorded

The current Supabase CLI account lists Main and a personal project, not staging.
Staging backup, migration deployment and isolated live verification are gated on
restored staging access. Oracle is reachable; its Node API/worker currently use
node-chatbot-engine:888ded9. No live application changes have been made.

## Local validation

- Full backend validation passed: Deno formatting/lint/type checks, plugin and
  voice-service checks, and 47 database suites / 1,001 assertions.
- The episode suite additionally passed 19 assertions after adding
  assigned-agent history visibility and restricted-history isolation checks.
- Integration worker: 34 tests, lint and TypeScript build passed.
- Snapshot freshness and bounded-recovery tests: three passed, including an
  unresponsive handler that cannot hold the HTTP response beyond the budget.
- Frontend: all 363 tests passed; backend type synchronization, full lint
  (warnings only), TypeScript and production Vite build passed. The worktree
  requires API_DB_TYPES_FILE to point at this backend's generated file.
- Node: build, lifecycle/takeover, two new episode integration tests, core,
  integration contracts, infrastructure, recovery, rules, API progress, typing,
  historical buttons/lists, CLI, real local database outage and worker-restart
  checks passed. An obsolete handoff mock was updated for current-conversation
  lookup. API-progress and historical-menu tests require their dedicated
  documented flags/database; only failed checks were repeated after correction.

No manual staging/browser/Meta end-to-end verification has been performed.
Neither staging nor Oracle live migrations, backups or deployments have run. The
feature branches are prepared for rollout only after the gates above.
