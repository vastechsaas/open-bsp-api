# Campaign module Main rollout — 2 November 2026

## Authorized scope

Promote all built campaign features for campaign users and Super Admin,
including delivery receipt counts and durable activity history. Preserve
unrelated Main/staging differences, existing sends, tenant settings and all PHP
behavior. No real templates may be sent by rollout checks. CSV export is not
implemented by this promotion.

Branches: `campaign-main-parity-backend`, `campaign-main-parity-ui`,
`campaign-main-parity-node`. Bases: backend `8cbe6f0`, UI `7fa5e88`, Node
`b519207`. An existing interrupted merge in the separate `carousel-main-rollout`
checkout was preserved; this rollout uses the clean campaign checkout.

## Features

- Existing carousel/media editor, campaign recipient snapshots, CloudAMQP
  transport, three-attempt retries and Needs review safety remain intact.
- Super Admin organization campaign policy: daily allowance, budget time zone,
  per-number submission rate, recipient rolling-24-hour cap and audit/revision
  checks.
- Campaign start scheduling and optional daily sending hours, with automatic
  waiting/resumption. No new user-selected speed or mandatory final deadline.
- Distinct accepted/sent/delivered/read/failure counts and paginated activity.
  No historical backfill or inferred delivery timestamps.
- Receipt recovery in the campaign worker and exact-byte late-receipt forwarding
  through the compatible integration worker and standalone Node API/worker.
- Main's existing authenticated status-only fast path is preserved and routes
  campaign receipts before attempting chat-message lookup. Pure campaign
  receipts cannot create placeholder conversations.

Existing policy enforcement remains unchanged. New policy rows default disabled;
no production limits are guessed or copied from staging test fixtures.

## Database and backup

Confirmed Main project: `buvjopvpkgvzhykwsxnk`. Its dry run lists exactly:

1. `20261030180254_scrum_140_campaign_sending_policy.sql`
2. `20261031203956_scrum_140_simplify_campaign_scheduling.sql`
3. `20261031214845_campaign_delivery_tracking.sql`

All applied successfully to an isolated local database at port55442. Types were
regenerated from that Main-only migration history and synchronized with the UI.
The local storage service schema differs from the long-running development
stack; generated storage-only differences do not change application migrations.

Pre-deployment Main affected-data/schema backup is Windows CurrentUser-DPAPI
encrypted in the owner-restricted ignored directory:
`node_modules/.campaign-main-ops/main-before-campaign-parity-20261102T142832Z.dpapi`.
SHA256: `72C7F0A07724A3807908CD8295FD30357F7958141D4EE2FCC39133E5A5C25593`.
Decrypt verification passed; the plaintext schema intermediate was removed.
Snapshot: two completed campaigns, four accepted deliveries and four accepted
jobs. No active dispatch was observed before migration.

Oracle Node backup:
`/opt/chatbots/deployment-backups/campaign-main-20261102/node-before.dump`.
SHA256: `72663ff56ccda5740a6974ee4367231d0719a336538b4e7456a036f2b4b56276`. The
root-only directory also retains previous Compose/private configuration;
`pg_restore --list` verification passed. No Node migration is required.

## Runtime artifacts and ordering

1. Apply Main schema and deploy campaign-dispatch, campaign-worker and
   whatsapp-webhook before dependent UI/runtime behavior.
2. Integration worker on130.61.190.252: compiled Main-compatible source
   `e7c0199`, image `openbsp-main-chatbot-worker:e7c0199`. Compose override:
   `/opt/chatbots/campaign-main-releases/e7c0199/compose.integration-campaign-main.yaml`.
   Existing project remains `openbsp-main-worker`, loopback8082.
3. Node API/worker: image `node-chatbot-engine:23a874d`. The Main candidate
   standalone source is byte-identical to tested staging `d5d2a66`; promote that
   existing artifact with Main revision label rather than reinstalling runtime
   dependencies. Override:
   `/opt/chatbots/campaign-main-releases/e7c0199/compose.node-campaign-main.yaml`.
   Existing project `node-chatbot`, API loopback4080. Infrastructure, webhook
   URL, credentials and tenant/flow selection remain unchanged.
4. Campaign worker on51.170.85.38: `openbsp-campaign-worker:e7c0199`, image ID
   `sha256:70ebda47bad2c37365329eb05dca25290d92f7801e0a264a65bf780da6f58261`.
   Existing Compose project `openbsp-campaign-production`, loopback8094,
   production queue namespace and Main backend configuration remain isolated.
   The image was built locally and loaded, avoiding a build on the1GiB host.
5. Merge/push the dependent UI; verify its configured production deployment.

Previous images retained: `node-chatbot-engine:b519207`,
`openbsp-main-chatbot-worker:665a2ea`, `openbsp-campaign-worker:9b92cda`, plus
explicit `before-campaign-main-20261102` rollback tags. Campaign Compose/env
backup: `/opt/openbsp/deployment-backups/campaign-main-20261102/`.

## Checks

- Dispatch handler/status adapters:25 focused tests passed, including tenant
  boundaries and Main status-lane compatibility.
- Campaign worker:17 unit tests passed; optional local broker test skipped.
  Production image build passed with pinned package lock.
- Integration worker:52 tests, lint and build passed.
- Node: build,9 boundary tests,57 core tests and4 receipt forwarding/persistence
  tests passed; no real sends or live tenant configuration changes.
- Frontend:466 tests, generated-type synchronization, lint (zero errors,
  existing377-warning baseline) and TypeScript passed; production build pending.
- Backend static/plugin/voice checks passed. Initial local database regressions
  identified missing standard Vault/billing fixtures in the isolated database;
  fixtures were initialized locally and only affected files are being rerun.

## Rollback

Keep additive schema and campaign evidence. Never reset accepted or uncertain
jobs, move them to the legacy sender, or resend to test recovery. Stop selection
of new policy-managed work first and reconcile outstanding reservations before
restoring a sender that lacks enforcement. Preserve compatible receipt ingestion
while Node events carrying `receipts_only` remain pending. Restore Compose/image
artifacts only in their named projects; do not touch PHP, voice or staging.

## Delivery evidence

Pending final validation, Main migration/deployment, no-send checks and branch
pushes. Update this section after verified completion.
