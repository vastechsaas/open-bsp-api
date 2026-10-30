# SCRUM-140: Campaign sending policies and automatic scheduling

Jira: https://hureram8.atlassian.net/browse/SCRUM-140

Status: planning only. No runtime code, migrations or live policy settings
changed.

Backend branch: `scrum-140-campaign-policy-backend`. UI branch:
`scrum-140-campaign-policy-ui`.

Planning bases: backend staging `4ac6239`; UI staging `0f94c47`. The existing
campaign worker belongs to the backend branch. No standalone chatbot-engine
branch is needed.

## Goal

Allow Super Admin to define organization-specific campaign limits while campaign
users schedule sends within those limits. Extend the SCRUM-133 CloudAMQP
foundation rather than introducing another queue service. PostgreSQL is
authoritative; Supabase authorizes/reserves every send; the existing Node worker
coordinates; CloudAMQP transports identifier-only notifications.

## Confirmed decisions

- Maximum campaign-message daily allowance shared across all campaigns/numbers
  in an organization.
- Maximum actual submission attempts per minute shared across campaigns on each
  sending number.
- Configurable per-recipient campaign frequency cap, shared across the
  organization over rolling 24 hours.
- Super Admin configures limits. Tenant users cannot raise or bypass them.
- Campaign users choose start date/time, campaign time zone, daily sending
  window and campaign expiry.
- Budget exhaustion automatically defers and resumes when ALL conditions permit.
  Manual-resume exhaustion mode is EXCLUDED; do not add a single-option
  behaviour dropdown.
- This is campaign-only. Ordinary agent/chatbot replies do not consume this
  allowance. Internal caps never increase or guarantee Meta allowances.

## Proposed v1 defaults/boundaries for refinement

- A daily allowance is a calendar day in the Super Admin-controlled organization
  budget time zone. Campaign sending time zone is separate and cannot reset
  quota.
- One daily sending window (all days), explicit campaign expiry; no recurring
  campaign generation or multiple daily windows.
- Limits are ceilings, not delivery-speed promises. Do not invent universal
  numeric defaults or Meta tiers; configure an isolated test policy during
  staging.
- Policy enforcement is opt-in/flagged during rollout, preserving existing
  behavior until an authorized complete policy is configured. Once enabled,
  missing/unreadable policy fails closed; require positive finite ceilings.
  Enabling requires the organization to use CloudAMQP for new runs. Existing
  legacy runs must drain before policy enablement, or use the same gate; never
  silently allow an uncapped legacy bypass or change in-flight transport.
- Preserve accepted sends, immutable audience/content snapshots, carousel
  behavior and Needs review safety. New scheduling does not replay the audience
  each day.

## Backend/database work

1. Schema-first organization policy storage, revisioned Super Admin-only
   read/save with stable request IDs, audit history and organization-private
   invalidation. Authenticated effective/read-only usage query exposes no
   credentials.
2. Extend campaign drafts/start/review with validated schedule, IANA time zone,
   daily window and expiry. Store absolute instants in UTC; use named time zones
   for local boundaries/DST. Define explicit next-day meaning for overnight
   windows and validate ambiguous/nonexistent DST input.
3. Durable usage/reservation records for daily allowance and canonical-recipient
   rolling frequency; durable per-number submission pacing. Initialize from
   trustworthy existing accepted campaign history so turning on a policy does
   not grant an extra fresh allowance.
4. Early eligibility check before expensive media preparation and final atomic
   check/reservation at the existing begin_campaign_dispatch_send boundary. Use
   database time and locks/fencing so simultaneous workers cannot overspend.
5. Accepted sends settle their reservation once, definitive rejections release
   appropriate count/frequency capacity, unsent abandoned preparation releases
   safely. Unknown/in-flight submissions retain conservative accounting and
   Needs review; never blindly resend or free uncertain capacity.
6. All actual submission attempts, including retries, respect the rate ceiling
   and smooth pacing. Broker retries, waiting and status polling consume no
   Meta-send attempt. Retain three total send attempts and existing uncertainty
   reconciliation.
7. Calculate the next instant satisfying start, window, expiry, daily allowance,
   number pacing and recipient frequency together. Persist safe waiting reason
   and next_eligible_at/due_at; expire unsent work after the deadline instead of
   silently completing it.
8. Recheck current policy on each sending decision. Limit reductions block
   subsequent submissions, not already accepted/in-flight sends.
   Budget-time-zone changes must not grant duplicate capacity.
9. Preserve existing authorization, account disconnect/archive/suspension
   checks, row isolation and internal endpoint authentication. API callers
   cannot bypass schedules/limits.

## Existing campaign worker

- Extend services/campaign-dispatch-worker in the backend slice; no standalone
  chatbot-engine branch.
- Publish only due work via the durable outbox. ACK a deferred notification only
  after its next eligibility and reason are committed. Recover from missing
  notifications/worker restarts using PostgreSQL.
- Never sleep a consumer until tomorrow, put credentials/content in MQ payloads,
  rely on RabbitMQ TTL as policy truth, or block other eligible organizations
  behind one capped organization.
- Add terminal-expiry/cancellation handling so late queue notifications cannot
  send.
- Ensure fair bounded progress across due campaigns/organizations; retain
  environment isolation, confirms, idempotency, status reconciliation and health
  checks.
- Deploy the compatible worker to the isolated staging Compose service on
  51.170.85.38:8093 first. Production worker8094 is NOT part of this initial
  rollout.

## UI

- Super Admin -> Organization -> Campaign controls: daily allowance, budget time
  zone, per-number sending ceiling and recipient rolling-24-hour cap; explicit
  Save, safe validation, revision conflicts, audit/reload behavior.
- Existing campaign wizard: Schedule & delivery (Send now/Schedule later, start,
  time zone, daily sending window, expiry, optional slower speed).
- Review shows policy ceilings, shared allowance usage, next eligible time and a
  plain-language schedule. Estimates are estimates, not guaranteed completion.
- Existing list/review shows Scheduled / Sending / Waiting for daily allowance /
  Outside sending hours / Recipient frequency wait / Expired, while retaining
  separate Needs review outcomes. Expose deferred/expired counts without calling
  them delivered or failed.
- Cancel unsent work through existing campaign-management authorization with a
  confirmation; cancellation does not retract accepted/in-flight messages.
- Translations, light/dark contrast, responsive layout, server pagination and
  organization/user cache isolation remain consistent.

## Implementation sequence/checklist

- [ ] Refine counting/time-boundary rules and migration/backfill design.
- [ ] Implement policy/schedule schema, protected RPCs, reservations and
      dispatch fences with database/Deno tests.
- [ ] Extend publisher/consumer eligibility, pacing, recovery and isolated
      worker tests.
- [ ] Build Super Admin policy and campaign scheduling/status UX after backend
      types are ready.
- [ ] Failure/race/DST/regression testing, no-send staging rollout, runbook and
      approval evidence.

## Acceptance

- [ ] Concurrent campaigns/numbers share the org daily ceiling; concurrent
      workers never overspend the last slot.
- [ ] Submission rate includes retries and never bursts the entire minute's
      allowance at once.
- [ ] Recipient caps deduplicate canonical identity across CSV/contact
      representations, campaigns and organization numbers.
- [ ] Waiting for any policy condition preserves the job and does not consume an
      attempt; eligible other work continues.
- [ ] Exhaustion at15:00 with a09:00-18:00 window resumes09:00 next eligible
      day, not midnight. Expiry wins.
- [ ] Policy edits, midnight/DST/overnight boundaries and time-zone changes do
      not create extra allowance.
- [ ] Duplicate notifications, status timeouts, restarts, expired preparation
      and uncertain submissions preserve reservations/idempotency.
- [ ] Stale notifications cannot send cancelled/expired work; unknown Meta
      outcomes remain Needs review.
- [ ] Disconnect, archival, role/API-key restrictions and tenant isolation are
      preserved.
- [ ] Standard/media/carousel payloads and existing campaign-history ingestion
      remain unchanged.
- [ ] Test opt-in behavior and existing/legacy-run safety; active campaigns
      never change transport.
- [ ] Focused tests per batch; one full backend/worker/frontend validation
      before delivery.

## Branches and delivery

Branches: `scrum-140-campaign-policy-backend` from latest `meta_vista_backend`
and `scrum-140-campaign-policy-ui` from latest `meta_vista_frontend`. Preserve
unrelated work. Planning first: no implementation, migration application,
deployment, policy enablement or customer sends authorized by ticket creation.
Selective future Main promotion must preserve its production worker
port8094/deployment isolation and Main-only changes; do not replace Main
wholesale with staging. For later implementation: edit schema sources,
generate/apply one migration locally, regenerate/synchronize types. Confirm
staging acifbsuxmpdtlhbsvhlj and back up affected data. Deploy compatible
backend + staging worker before UI behind disabled policy enforcement; verify
with isolated tenant and mocked Meta. No actual template sends without separate
recipient authorization. Main merge, production migration/worker deployment and
tenant enablement require subsequent approval. Rollback must preserve policy
gates for already-policy-managed work: stop new selection, reconcile/drain
pending reservations/jobs, retain compatible worker/handler and additive data;
do not simply disable enforcement and release blocked work.

## Out of scope

Manual-resume exhaustion choice; recurring campaigns; multiple daily windows;
advanced campaign-priority UI; monetary budgets; automatic Meta-limit discovery;
consent/opt-out registry implementation; delivered/read reporting; ordinary
chatbot/PHP/Instagram processing changes.

## Estimate and related work

Provisional estimate:8-12 engineering days, including staging verification;
refine after reservation/backfill review. Related foundations: SCRUM-133
(CloudAMQP), SCRUM-132 (carousel), SCRUM-33/34/35 (campaign execution). Source:
this conversation's Product/Architecture proposal and explicit exclusion of
manual resume; no separate Confluence specification supplied.
