# Campaign delivery tracking and activity history

## Tracking

- Jira access checked on 2026-11-01: connector requires reauthentication. This
  file is the fallback tracker; no Jira issue has been created.
- Backend branch: `campaign-delivery-tracking-backend` (from
  `meta_vista_backend`, `65e1847`).
- UI branch: `campaign-delivery-tracking-ui`, from frontend staging `53c715d`.
- Node branch: `campaign-receipt-forwarding-node`, from Node Main `b519207`, in
  the clean `scrum-120-node-main-merge` checkout. Unrelated Node work is
  preserved.
- Staging target: `acifbsuxmpdtlhbsvhlj`. Main and live DKR/PHP are out of
  scope.

## Scope and safeguards

Track signed sent/delivered/read/failed receipts separately from dispatch
outcomes. Persist deduplicated lifecycle activity, expose authorized summary
counts and paginated activity, and retain unmatched receipts for race-safe
reconciliation. Never resend because a receipt is missing or reports failure. No
historical backfill, advanced log search, exports, new webhook URL, or new
queue. No actual template sends without separate authorization.

Include late-receipt forwarding for known Node mappings after
disconnect/suspension, without enabling automation. Preserve signed bodies and
mixed-batch tenant checks.

## Implementation checklist

- [x] Backend schema, lifecycle events, receipt ingest/reconciliation and
      authorized read RPCs.
- [x] Campaign correlation for both transports and campaign-first webhook
      routing.
- [x] Focused SQL/webhook/payload/recovery tests.
- [x] One generated migration, local application and generated UI/backend types.
- [x] Existing campaign page: counts, activity pagination, translations and
      tests.
- [x] Isolated Node branch: durable forwarding and gate regression tests.
- [x] Full validation per changed repository.
- [x] Confirm staging reference and back up affected data.
- [x] Deploy backend before dependent UI; deploy isolated Node/worker changes as
      needed.
- [x] Verify staging with mocked sends and signed receipt fixtures.

## Rollout evidence

Generated migration `20261031214845_campaign_delivery_tracking.sql` applied
locally and to staging. Known unrelated grant revokes from the generator were
removed before local application, and explicit private function/table ACLs
restored. Generated types were synchronized once. No actual template send
occurred.

Checks on 2 November 2026:

- Backend full validation: 62 SQL files / 1,477 assertions passed, static/plugin
  checks and voice tests/build passed. Expanded focused SQL checks: 51 passed.
- Webhook receipt adapter: 6 tests passed, including mixed-batch isolation.
- Integration worker: 36 tests passed; build/lint passed after repairing local
  dependency installation.
- Node build, 9 boundary/routing tests, 57 core tests and 2 receipt
  gate/envelope tests passed. All 4 focused gate/persistence tests also passed;
  the final lookup follow-up passed focused tests and TypeScript checks.
- Frontend: 475 tests, type synchronization, lint (0 errors) and production
  build passed. Final changed-file lint passed without warnings after query-key
  and safe-count typing cleanups.
- Campaign worker: 16 unit tests and build passed; its optional local broker
  integration test remained skipped. Staging connectivity/readiness was
  verified.

Staging backup:
`node_modules/.campaign-tracking-backup/staging-before-campaign-tracking.dpapi`,
Windows CurrentUser-encrypted schema and affected campaign data,
decrypt-verified; SHA256
`7625517481CC1906C1C11A5A3B568CD98356400A0A3B6096FEEC8993EA1EAD52`. Snapshot
contains 9 campaigns, 6 deliveries and 6 jobs. The staging dry run lists only
this migration and explicitly reports `dryRun: true`.

Isolated Oracle Node backup:
`/opt/chatbots/node-engine-staging/backups/campaign-tracking-20261102/`,
root-only directory containing a custom-format database dump and retained
private configuration. Database SHA256
`bcbe6aca0e073a99bd38aa7a112667cf6bf8d74bb1a5aeb0298165e354b3e786`. Previous
staging image: `node-chatbot-staging:b519207c525f31716a16c4e02f41f25be4e8ff12`.

The optional `receipts_only` envelope field requires the integration worker to
deploy before Node. It is authenticated with the existing tenant credential and
does not create a new public API or queue. Campaign worker recovery now invokes
the bounded receipt reconciler; that staging container is deployed too. Main
rollout requires separate approval.

## Verified staging delivery — 2 November 2026

- Backend feature `c0d089d`, staging merge `4f4991a`; UI feature `1f3174b`,
  staging merge `38a739e`. Both staging branches are pushed. Node feature
  `4f41f2d` plus lookup follow-up `d5d2a66` are pushed only to
  `campaign-receipt-forwarding-node`, not Node Main.
- Staging migration ledger confirms `20261031214845`. A manual push raced the
  merge-triggered deployment and reported an existing table; nothing was dropped
  or rebuilt. The subsequent dry run reports up to date. Private ingest
  execution is denied to authenticated users and granted to the service role.
- Deployed `whatsapp-webhook`, `campaign-dispatch` and `campaign-worker` to
  `acifbsuxmpdtlhbsvhlj`. Browser reads exercised the new RPCs using the normal
  authenticated owner session.
- Integration host `51.170.85.38`: staging integration and campaign workers run
  `openbsp-chatbot-worker:c0d089d` and `openbsp-campaign-worker:c0d089d`. Both
  readiness checks pass. Immutable source and Compose overrides are under
  `/opt/openbsp/releases/campaign-tracking-c0d089d/`. The previous integration
  image is retained as
  `openbsp-chatbot-worker:before-campaign-tracking-20261102`; previous campaign
  images remain. Production campaign worker stays `9b92cda`.
- Isolated Node API/worker on `130.61.190.252` run
  `node-chatbot-staging:d5d2a66`, API loopback port 4081. Source is under
  `/opt/chatbots/node-releases/campaign-receipts-d5d2a66/`; its override is
  `/opt/chatbots/node-engine-staging/compose.campaign-receipts.yaml`. Original
  private infrastructure and previous images remain. Live DKR's API/worker
  remain `b519207`, untouched.
- Signed synthetic Node verification passed for disconnected and suspended
  accounts, duplicate delivery and exact-byte preservation. Each run forwarded
  two receipts to an exclusive queue on **private staging RabbitMQ**, with zero
  bot executions, outbound dispatches, conversations or Meta sends. Only
  synthetic tenant `141141` has a test forwarding route; no real Node tenant
  route was enabled.
- `scripts/verify-node-campaign-receipts.cjs` is the reusable Node harness. Pipe
  it into `node` inside the isolated staging worker; it checks the staging
  exchange and private broker hostname before writing its synthetic fixture.
- `scripts/verify-campaign-tracking-staging.sql` uses explicit fixture IDs and
  never calls a global claimant. An earlier attempt to reuse the disposable
  local test on shared staging was rejected by a stale existing lease and rolled
  back; no existing campaign state was committed by that attempt.
- The retained UI fixture is `14114100-0000-4000-8000-000000000099`, **Receipt
  tracking verification — SIMULATED, NO SENDS**, in **SCRUM-128 PSDF isolated
  sync test**. It has three synthetic recipients and 15 activity events on a
  disconnected fake number. It is completed and cannot be run. Its first
  synthetic version was recreated with its CSV snapshot, without editing started
  immutable content or customer data.
- Browser verification confirmed Accepted 3, Sent 3, Delivered 2, Read 1,
  Delivery failures 1, separate Dispatch failures 0, translated labels, and
  pagination from 10 newest events to 5 older events on page 2.
- Comparison against the encrypted backup confirms all original **9 campaigns, 6
  deliveries and 6 jobs** retain their states, attempts, WAMIDs and counters.
  Only the isolated verification campaign/recipients were added.
- No actual template was sent. These signed synthetic receipt, contract,
  database and UI checks are not proof of delivery to a real WhatsApp handset; a
  real Meta send remains separately authorized work.

Image builds reported existing vulnerabilities in unchanged Node/integration
dependencies. No forced upgrades were included; assess those as separate
maintenance before production rollout. Main Supabase, Main branches, PHP and
live chatbot services remain unchanged.

## Rollback

Restore compatible application images only after disabling new reporting writes.
Retain additive schema and stored evidence. Do not reset deliveries, requeue
accepted submissions, or hand uncertain work to another sender.
