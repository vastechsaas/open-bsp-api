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

Main rollout is not authorized. Capacity has been confirmed by the user; monitor
resource usage and broker backlog under the staging load before future rollout.
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

## Verified staging release — 29 October 2026

- Backend application revision: `9b92cda`; UI revision: `0f94c47`. Both are on
  their respective staging branches; Main was not merged.
- Generated migration `20261029155151` was backed up and applied to
  `acifbsuxmpdtlhbsvhlj`. Worker-only execution grants were verified remotely.
  The diff's unrelated revoke noise was removed and explicit new-function ACLs
  restored with user-approved local migration repair before remote deployment.
- Worker host: `51.170.85.38`. Runtime deployment directory:
  `/opt/openbsp/campaign-dispatch-staging`; project: `openbsp-campaign-staging`.
  Invoke Compose with `-f /opt/openbsp/campaign-dispatch-staging/compose.yaml`
  and `SOURCE_REVISION=9b92cda`. Runtime uses a separate protected `.env`.
- Image: `openbsp-campaign-worker:9b92cda`, digest
  `sha256:c0448e2f2f314e21900c04471688942d4396ac306aff7188465e7502f1aace97`.
  This is the first campaign-service deployment; retain this image for rollback
  from future updates. No existing service image was replaced.
- Only `SCRUM-133 Campaign Dispatch Test`, organization
  `13313300-0000-4000-8000-000000000001`, is enabled. Its account is
  deliberately disconnected. One queue-to-backend smoke job failed with zero
  sends; a second simulated submitting job recovered to Needs review without a
  resend. The staging DLQ retains these two safe test notifications for
  inspection.
- Readiness returned true; observed worker memory was about 42 MiB within its
  256 MiB limit. Existing chatbot/voice container IDs and start times were
  unchanged. The staging frontend deployment completed successfully.
- Validation: 1,366 database assertions across 60 files; 461 frontend tests and
  build; 11 handler tests; worker unit tests plus real local RabbitMQ routing,
  confirmation, consumption and unroutable-publication checks passed.
- Backup directory on the deployment workstation:
  `C:/Hurera New Laptop/backups/scrum-133-staging-20261029`. No actual Meta
  template send was performed. Live-recipient approval, marketing launch
  safeguards and Main rollout remain separate decisions.
