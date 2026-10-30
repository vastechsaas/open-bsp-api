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
