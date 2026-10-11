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
- Frontend: full validation passes: 353 tests, matching generated types, lint
  (zero errors; 389 existing/non-blocking warnings), TypeScript and Vite build.
- Node: boundaries/routing 9, core 57, lifecycle 6 and focused takeover/episode
  tests pass; Prisma generation and TypeScript build pass. New BUTTON and LIST
  integration cases prove historical selection while queued, duplicate
  suppression and no bot response after confirmed takeover. Tests use guarded
  disposable local tenants only and simulate Meta sends without contacting real
  customers.

## Rollout and verification

Deploy compatible Node API/worker and backend before the dependent UI. Back up
the target database first and confirm the linked Supabase project. Main needs
staging's already-generated `20261006155552_support_inbox_visibility.sql`; do
not generate a duplicate migration or apply it again on staging where it already
exists. No Node migration is needed.

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

## Deployment record — 2026-10-11

- Backend feature commit: `785717d`; staging port: `45fce39` plus documentation
  formatting `e553b88`. Both target branches have the focused fix; unrelated
  worker-latency and validation-editor differences are not merged between them.
- Main support-inbox migration was the only pending migration in the verified
  dry run. It was applied to `buvjopvpkgvzhykwsxnk`; a subsequent dry run
  reports no pending migrations. `chatbot-management` was deployed to Main.
  Supabase's Git integration also reports success for staging and Main.
- Main backups are outside Git in
  `C:/Users/Hurera Mujeeb/.codex/backups/support-lifecycle-20261011-main-*.sql`:
  schema, COPY-format public/billing/auth/storage data and roles. These include
  sensitive data and storage metadata, not storage file contents.
- Oracle API and worker run `node-chatbot-engine:c072ca8`, merged from Node
  Main. Prisma reported seven applied migrations and none pending. API readiness
  and HTTPS `/readyz` returned healthy; the worker reported ready with zero
  restarts.
- Oracle's private backup directory is
  `/opt/chatbots/node-engine/backups/support-lifecycle-20261011`. It contains
  the PostgreSQL custom dump (restore list verified), environment and prior
  compose configuration. Retained image:
  `node-chatbot-engine:rollback-support-lifecycle-20261011` (`5cd21f0`).
- The staging UI port includes its missing shared lifecycle/Previous chats
  prerequisites (`b2504e1` and `f6af31b` from Main) before the two focused
  fixes. Staging checks pass 370 tests, generated-type synchronization and
  TypeScript.
- Frontend Main is `d00f9ba`; staging is `70e2d1f`. Vercel confirmed successful
  production deployments for Main (`open-bsp-ui`, deployment
  `GvrwP3iUVMcbHGcjucwpCyUQ84Fz`) and staging (`meta-vista-ui`, deployment
  `3aASUSN7fu95KbpecvfG1ranjxGr`). Previous chats uses the system theme,
  translated controls/statuses and locale-aware dates. The sidebar/workspace
  label is Settings; the Preferences subsection remains Preferences.
- Main's initial CI failure was documentation formatting only, corrected by
  `197ed37`. Backend CI and Supabase deployment checks then passed on Main and
  staging. Node API HTTPS and PHP HTTPS both returned HTTP 200; PHP 8.2-FPM and
  Nginx remain running. No PHP configuration was changed.
- The CLI account cannot access staging directly. Staging deployment
  confirmation comes from its successful Supabase Git integration check; no
  direct staging database changes or backup were attempted after that
  authorization failure.
- PHP, queue-worker images, Meta webhook configuration and the active DKR flow
  remain unchanged. No customer messages or live takeover/closure actions were
  performed. The live first-click and waiting-menu acceptance checks above
  remain necessary; health and automated tests are not a substitute for them.
