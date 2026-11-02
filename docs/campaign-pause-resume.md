# Manual campaign pause/resume

Tracking: Jira account reports no supported Atlassian site; story creation
pending. Branches: `campaign-pause-resume-backend`, `campaign-pause-resume-ui`.
Target: staging `acifbsuxmpdtlhbsvhlj` only. Main is not authorized.

## Contract

Owner/Admin/Member use `pause_campaign` or `resume_campaign` with organization,
campaign, expected control revision and stable request UUID. Refresh campaign
state after success or ambiguous failure; retry the same action using the same
UUID and revision. Concurrent conflicting actions return SQLSTATE `40001`.

Only unfinished CloudAMQP campaigns support manual controls. Pause does not
alter dispatch outcomes, attempt counts, immutable content, receipts or sending
policy. The final send-authorization boundary fences unsent work. Sends already
authorized may finish. Resume retains retry due dates and rechecks
windows/budgets/rate caps. Already queued notifications return the existing
durable `deferred` response; no Oracle worker/runtime or chatbot changes are
required.

## Rollout/checklist

- [x] Focused database: 183 assertions; dispatch handler: 15 tests; UI: 18
      tests.
- [x] Two real local database sessions verify both pause/send lock orderings.
- [x] Existing campaign worker: 16 passed, one broker integration test skipped.
- [x] Generate/apply one schema migration and synchronize generated types.
- [x] Complete backend validation: 63 database files, 1,510 assertions, all
      passed.
- [ ] Complete frontend validation.
- [x] Confirm staging identity; back up affected campaign data/schema.
- [ ] Deploy backend before UI; merge/push staging only.
- [ ] Isolated no-send staging verification.
- [ ] Record commits/checks and Jira reference.

Rollback must retain the pause-aware database gate until held campaigns are
reconciled explicitly. Never restore a pause-unaware backend over active holds.
No real templates may be sent during tests.

Migration: `20261102162743_campaign_manual_pause_resume.sql`. Removed only known
unrelated table grant-revoke noise and restored explicit execution grants for
new/recreated RPCs before applying locally; no old migrations changed.

Encrypted pre-deployment backup (Windows current-user DPAPI) is in ignored
`node_modules/.campaign-controls-backup/staging-before-campaign-controls.dpapi`.
SHA-256: `A6A95DD3D4E0ADE940DC8BC7DEAACDCE54919F5B75C362897F2C268540620681`.
Snapshot: 10 campaigns, 9 deliveries, 6 jobs plus recipients, ledger, receipts
and activity; public schema included. Round-trip decryption verified. Dry run
lists only the new manual-control migration.
