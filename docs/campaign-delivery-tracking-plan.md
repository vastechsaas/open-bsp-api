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
- [ ] Isolated Node branch: durable forwarding and gate regression tests.
- [ ] Full validation per changed repository.
- [x] Confirm staging reference and back up affected data.
- [ ] Deploy backend before dependent UI; deploy isolated Node/worker changes as
      needed.
- [ ] Verify staging with mocked sends and signed receipt fixtures.

## Rollout evidence

Generated migration `20261031214845_campaign_delivery_tracking.sql` applied
locally only. Known unrelated grant revokes from the generator were removed
before local application, and explicit private function/table ACLs restored.
Generated types were synchronized once. No remote migration or template send has
occurred yet.

Checks on 2 November 2026:

- Backend full validation: 62 SQL files / 1,477 assertions passed, static/plugin
  checks and voice tests/build passed. Expanded focused SQL checks: 51 passed.
- Webhook receipt adapter: 6 tests passed, including mixed-batch isolation.
- Integration worker: 36 tests passed; build/lint passed after repairing local
  dependency installation.
- Node build, 9 boundary/routing tests, 57 core tests and 2 receipt
  gate/envelope tests passed. Additional persistence mock tests are in progress.
- Frontend: 475 tests passed; full lint/build still in progress.

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
the bounded receipt reconciler; deploy that staging container too. Main rollout
requires separate approval.

## Rollback

Restore compatible application images only after disabling new reporting writes.
Retain additive schema and stored evidence. Do not reset deliveries, requeue
accepted submissions, or hand uncertain work to another sender.
