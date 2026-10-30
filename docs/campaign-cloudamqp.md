# Campaign CloudAMQP processing (SCRUM-133)

Postgres remains authoritative. A campaign's transport is selected once at Run.
`campaign_dispatch_settings` is service-only and defaults off. Existing runs
remain `postgres`; the legacy claimant excludes `cloudamqp`. Disabling the flag
does not migrate or abandon active work.

The transactional `campaign_dispatch_jobs` records contain identifiers and safe
error codes only. A stable job identifies one of at most three attempts. The
publisher leases outbox rows, uses mandatory persistent publication with
confirms, and records confirmation. Confirm/write crashes can duplicate
notifications but cannot create another attempt. Pending notifications are
republished after five minutes, including retry-queue notification loss. The
consumer verifies envelope identity against the authoritative backend record
before processing.

`campaign-dispatch/jobs/:id` accepts GET status and POST process, both protected
by the existing internal `EDGE_FUNCTIONS_TOKEN` (service-key fallback only when
unset). The worker uses a separate Supabase service key for worker-only database
RPCs. The handler reuses Meta/media helpers; tokens stay in Supabase. It commits
`submitting` before the external request. Recovery requeues expired preparation,
but expired submission becomes `needs_review`, never another send. Only the same
fenced attempt can reconcile a late known WAMID. Actual Meta send attempts
increment at the submission boundary. Definitive transient failures get two
delayed retries (30/60 seconds plus jitter).

## Deploy to staging

1. Confirm project `acifbsuxmpdtlhbsvhlj`. Back up affected campaign tables and
   schema. Apply generated migration, verify worker-only grants, and deploy the
   compatible campaign-dispatch/legacy functions with tenant flags off.
2. Build the reviewed commit's new service. Configure a separate owner-only
   `.env` (`chmod 600`), never copy Meta tokens or secrets into queue payloads.
3. `SOURCE_REVISION=<commit> docker compose -p openbsp-campaign-staging up -d --build`
   from `services/campaign-dispatch-worker`. Retain the previous image. The
   health port binds localhost only at 8093. No Meta webhook change is needed.
4. Verify `/healthz`, `/readyz`, logs, and namespace
   `openbsp.staging.campaign.*.v1`. Never use production/chatbot queues for
   tests.
5. Deploy the minimal UI. Exercise mocks and crash/recovery tests; do not send
   actual templates without recipient authorization. Enable only the isolated
   staging organization's settings through deployment SQL after verification.

Main rollout was authorized on 30 October 2026. Use a separate production
Compose project and protected environment, `DEPLOYMENT_ENV=production`, Main
project `buvjopvpkgvzhykwsxnk`, and `HEALTH_PORT=8094`. Never point the staging
container at Main. Production queues use `openbsp.production.campaign.*.v1`.
Capacity has been confirmed by the user; monitor resource usage and backlog.
There is no configurable rate/daily-budget control in this migration. Consumer
prefetch one is concurrency, not a sending limit. Never infer launch readiness
for a real marketing audience from these queue checks alone.

## Review and recovery

Use the campaign UI Needs review count and safe delivery/job reference. Inspect
the corresponding job in the database and broker DLQ with restricted operator
access. Do not replay DLQ messages as a resend mechanism. GET status is
read-only. If an operator has a verified WAMID for this exact submitted attempt,
invoke `finish_campaign_dispatch_job` with that job's retained lease token and
accepted outcome; the write is idempotent. Without evidence, leave the job in
Needs review. No automatic resend, force retry or queue-administration UI is
provided.

Publisher/consumer logs contain correlation IDs and phases only, not raw
provider errors, phone numbers, templates, broker URLs or credentials. Malformed
payloads produce sanitized DLQ records rather than copying untrusted content.

## Rollback

Disable new-run selection first. Keep the compatible worker/backend until all
existing AMQP jobs are drained or reconciled. Review uncertainty separately; do
not reset it to queued or change the campaign's transport. Retain additive
schema and legacy claimant's transport filter. Only then stop the new service.
Restoring an old batch sender without the filter can duplicate delivery and is
unsafe.

## Main release — 30 October 2026

The user approved selective Main promotion and CloudAMQP selection for all
organizations present at rollout. Future organizations still default to the
legacy transport unless explicitly enabled. Existing campaign runs never change
transport. No actual template send or campaign start was performed for this
release.

Final verification: all **23 current Main organizations** have their setting
enabled. At enablement there were zero campaign jobs and zero legacy campaigns;
no runs were migrated. The Main UI deployment for `4b83853` succeeded, and its
public English locale serves the new Needs review/reference labels. Production
and staging workers both remained ready after enablement.

- Backend: `5432cd6` and `f738371` promote the staging campaign implementation;
  `0c04579` adds the isolated production health-port configuration and test.
  Frontend: `4b83853`. Main's carousel code and unrelated features are
  preserved.
- Main project `buvjopvpkgvzhykwsxnk` was verified. The dry run selected only
  `20261029155151_scrum_133_campaign_cloudamqp.sql`; it was applied
  successfully. The new `campaign-dispatch` function is deployed. Authenticated
  nonexistent-job status returns 404; requests without internal authentication
  return 401. Tenant/anonymous worker execution is denied; service-role
  execution is allowed.
- Before migration, affected data, function definitions/ACLs, constraints,
  triggers, column metadata and migration history were backed up and round-trip
  verified using the current Windows user's DPAPI protection, outside Git:
  `C:/Users/Hurera Mujeeb/.codex/backups/campaign-main-2026-10-30/before-cloudamqp-f54612f373f3446e9c4c78901a4225cd.dpapi`.
  SHA-256: `248D6FBD80E933C46BAE87DAEC120D852B62D608AF89D967E2B9CDB0D061CCEA`.
  Campaign and delivery tables were empty at backup time.
- Oracle host `51.170.85.38`, directory
  `/opt/openbsp/campaign-dispatch-production`, Compose project
  `openbsp-campaign-production`, loopback readiness port **8094**. The
  root-owned environment file is mode 600 and contains Main-only backend
  credentials. Application source is unchanged from reviewed image
  `openbsp-campaign-worker:9b92cda`, digest
  `sha256:c0448e2f2f314e21900c04471688942d4396ac306aff7188465e7502f1aace97`.
  This exact image was reused, not rebuilt or mislabeled as a newer source SHA.
- Production queues are `openbsp.production.campaign.*.v1`; staging stays on
  `openbsp.staging.campaign.*.v1` and port 8093. Readiness and queue inspection
  verified one consumer per dispatch queue. The production queues were empty;
  staging retained its two intentional DLQ test notifications. Existing chatbot,
  voice and staging-campaign container start times were unchanged.
- Validation: 14 worker unit tests and build; 19 focused Deno tests; 448 UI
  tests, strict paired database-type check, TypeScript and Vite build. UI lint
  had zero errors and the existing 373-warning baseline. Full backend checks ran
  1,334 SQL assertions: one unrelated Main-vs-staging permission metadata
  mismatch was resolved by a successful 42-assertion rerun using Main's
  schema-source function inside a rolled-back transaction. The shared local
  database was not changed. Main's live public/billing type blocks match the
  release; managed Storage and hosted PostgREST generator metadata differ from
  local generation and were not imported as unrelated type churn.

Rollback: disable the relevant `campaign_dispatch_settings` rows for new runs,
then drain/reconcile existing CloudAMQP jobs before stopping only the production
Compose project. Keep the additive migration, legacy transport filter and image.
Do not switch the staging container to Main or replay unresolved jobs through
the legacy sender. Configurable scheduling/throttling, consent and delivery/read
reporting remain separate work; these checks are not a live marketing-send test.
