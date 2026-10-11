# Support lifecycle consistency

## Intended behavior

Requesting human support makes the existing conversation eligible for the
support inbox and normal queue assignment. It does **not** transfer execution
ownership: the customer can keep using chatbot menus until an authorized agent
takes control. Confirmed takeover pauses the chatbot, invalidates previous menus
and cancels obsolete replies/delays. Resolve & close retains the existing race
checks and separate-conversation episode behavior; it sends no closing message.

## Findings and changes

1. Episode-enabled Node conversations explicitly suppressed ingestion,
   historical menu execution, delayed continuation and dispatch when support was
   `waiting`. Those waiting-only guards are removed. Human ownership,
   closed/obsolete episodes, suspension, blocked contacts and disabled bots
   still prevent execution. The terminal handoff branch ends its session without
   cancelling ordinary planned replies or invalidating menus just because
   support was requested.
2. Main did not contain staging's support-inbox eligibility predicate and UI
   filtering. Reuse that implementation, its existing generated migration and
   its tests. This is presentation filtering, **not** a restriction on message
   storage or a replacement for existing RLS/queue-access rules. Bot-only Node
   conversations are hidden; waiting/handled support and resolved history remain
   eligible.
3. A lifecycle response of `enabled: false` stopped polling even when the number
   was Node-managed and its mapping was still arriving. Return
   `awaiting_mapping`, poll that state and waiting support every two seconds,
   and invalidate the shared lifecycle query on support-inbox broadcasts, focus
   and connection recovery. Missing/unconfirmed mapping state never grants human
   sending permission.
4. Action preflight previously read the local snapshot while reconciliation ran
   in the background. Action GETs now use `refresh=1` to await bounded Node
   reconciliation and reread the confirmed snapshot. Ordinary status reads
   remain local/asynchronous. An accepted action retains its request-specific
   pending UI fence until its own terminal result; stale reads/older
   acknowledgments cannot silently clear it. Failed header actions show a
   visible error toast as well as existing error/Retry controls. Closure still
   requires the latest customer message to be present in the open chat and is
   rejected if newer input arrives.

Read-only Main diagnostics showed successful persisted takeover/close
operations, not a reproducible failed first-click record. The first-click change
addresses confirmed stale-preflight and prematurely cleared UI-state paths;
browser/live verification is still required before claiming that every reported
symptom is resolved in the deployed system.

## Branches

- Backend: `codex/support-lifecycle-consistency-backend` (from Main).
- Frontend: `codex/support-lifecycle-consistency-ui` (from Main).
- Standalone Node: `codex/support-lifecycle-consistency-node` (from Main).

No latency-worker candidate, WhatsApp Flow work, PHP changes or DKR definition
edits are included.

## Checks

- Backend quick and full validation pass; 47 database test files / 1,003
  assertions, including 23 support-inbox assertions.
- Focused lifecycle, takeover readiness, bridge operation/processor tests: 14
  passed.
- Frontend: full validation passes: 350 tests, matching generated types, lint
  (zero errors; 389 existing/non-blocking warnings), TypeScript and Vite build.
- Node: boundaries/routing 9, core 57, lifecycle 6 and focused takeover/episode
  tests pass; Prisma generation and TypeScript build pass. New BUTTON and LIST
  integration cases prove historical selection while queued, duplicate
  suppression and no bot response after confirmed takeover. Tests use guarded
  disposable local tenants only and simulate Meta sends without contacting real
  customers.

## Rollout and verification

This branch is not a live deployment. Deploy compatible Node API/worker and
backend before the dependent UI. Back up the target database first and confirm
the linked Supabase project. Main needs staging's already-generated
`20261006155552_support_inbox_visibility.sql`; do not generate a duplicate
migration or apply it again on staging where it already exists. No Node
migration is needed.

Verify on an explicitly authorized test customer:

1. Bot-only messages are stored but absent from support inbox/queue counts.
2. Request support; the thread appears with its history and existing queue
   rules.
3. Use both a previous button and list option while queued; bot responds
   normally.
4. Confirm takeover appears after delayed mapping/event delivery and remains
   disabled while ownership is unconfirmed. Take control; only then does the bot
   stop answering and human sending become available.
5. Resolve on the first click: pending state stays visible until confirmed
   Closed. Test new input during closure, Node failure, reconnect and stale
   acknowledgments.
6. Confirm Closed history stays visible; a later customer message creates one
   fresh bot episode. Check assigned-agent/manager permissions and another
   tenant.

Do not roll the UI back to an older "chatbot paused while waiting" label while
the new Node behavior is active. Restoring the previous Node image restores its
old waiting behavior; no schema removal or history deletion is part of rollback.
