# SCRUM-140 campaign policy operations

## Where to configure

- Super Admin → Organization → Campaign controls: enable enforcement, daily
  message allowance, budget time zone, sends/minute/number and recipient cap.
- Campaign configuration → Schedule & delivery: Send now / later, time zone, and
  an optional daily sending window. New campaigns have no final deadline or
  user-selected speed; Super Admin controls the limits and campaigns continue
  across eligible windows/days until their audience is processed.
- Review and campaign listings show durable waiting reasons; review also shows
  usage, next eligibility, expired/cancelled counts and cancellation controls.

Policies start disabled. No arbitrary limits are assigned to existing tenants.
Enabling requires CloudAMQP selection and no queued/processing/uncertain runs.
Tenant role permissions are unchanged. Only Super Admin may configure policy.
Changes require the current revision and a stable save request ID. Reload after
a conflict rather than silently overwriting another administrator's changes.

## Counting and time rules

- The organization calendar-day allowance uses its budget time zone, not the
  campaign's zone. Accepted and unresolved reserved submissions consume it.
- Recipient frequency is a rolling 24-hour ceiling across organization numbers
  and campaigns. Phone formatting such as `+`, spaces and dashes is normalized.
- The per-number rate includes rejected submissions and retries, with smooth
  spacing as well as a rolling minute ceiling. Campaign speed may only lower it.
- Reservations happen atomically immediately before the existing send call.
  Preparation, broker redelivery and policy waiting spend no send attempt.
- Confirmed rejection releases count/frequency allowance, not rate history.
  Uncertain sends retain reservations and Needs review; never resend them
  blindly.
- Recent accepted legacy history seeds the ledger on policy configuration.
  Deleting a campaign does not erase its accounting. Budget zone changes are
  blocked for 48 hours after recent submissions to prevent quota resets.
- Sending requires all limits, the start and daily window to permit it. After
  midnight, a 09:00–18:00 campaign waits until 09:00. Overnight windows cross
  midnight. Local start inputs reject missing or repeated DST times.
- Existing explicitly configured deadlines/speed overrides remain compatible in
  the backend and on already-started campaigns. The simplified editor discloses
  that saving an older draft clears those two settings. No existing records are
  automatically rewritten. Review still shows any historical deadline.
- Expiry/cancellation stops unsent work, not an accepted/in-flight submission.
  Recovery processes this even if no queue notification arrives. No automatic
  customer message is sent by expiry/cancellation.

These are campaign-message controls, not billing budgets or Meta limit upgrades.
Agent and chatbot replies do not consume them. Existing three-attempt retry and
Needs review handling remain in effect; accepted does not mean delivered/read.

## Worker and queue responsibilities

PostgreSQL is authoritative. Early checks avoid unnecessary media preparation;
the final database fence reserves capacity under an organization lock. The
publisher only selects due work and bounds progress across organizations and
campaigns. Deferred jobs persist their reason/time and release the consumer.
CloudAMQP carries identifier-only notifications, not credentials or policy
truth.

The staging service is `/opt/openbsp/campaign-dispatch-staging` on
`51.170.85.38`, health port `8093`, Compose project `openbsp-campaign-staging`.
Use reviewed commit-tagged images and retain `openbsp-campaign-worker:9b92cda`.
Production service/port `8094`, chatbot and voice containers must not be changed
by this staging rollout. SQL/Edge support must be present before enabling a
policy.

## Validation and recovery

```powershell
npm run db:test -- supabase/tests/campaign_sending_policy.sql
node scripts/test-campaign-policy-concurrency.mjs
```

The second check is local-only. It commits exact disposable test fixtures for
two-connection visibility, performs no external sends, then purges only those
fixtures. It refuses to overwrite pre-existing fixtures.

For delayed work, inspect its persisted waiting reason, next time, active
policy, account state and campaign expiry. Do not manually move it to the legacy
sender or increment attempts. For Needs review, reconcile the existing
job/message ID using the SCRUM-133 runbook; do not create another send attempt
to test recovery.

Rollback first prevents new policy-managed campaigns. Drain or reconcile
existing work and reservations while retaining a compatible handler/worker and
additive schema. Do not merely switch enforcement off or restore a sender that
bypasses policy gates. The save RPC rejects disabling enforcement while work
remains. Main promotion and real recipient sends require separate approval.

## Staging release evidence — 1 November 2026

- Backend feature `aa95acb`, staging merge `05118c6`; UI feature `f10cdb6`,
  staging merge `310285a`. The existing staging carousel preview fix was
  retained.
- Project `acifbsuxmpdtlhbsvhlj`, migration `20261030180254`; campaign-dispatch
  Edge Function deployed. New function privileges and repaired recovery verified
  remotely. The newly applied local alias repair was explicitly approved.
- Encrypted affected-data backup (Windows current-user DPAPI, owner-restricted
  directory): `node_modules/.scrum140-backup/staging-before-scrum140.dpapi` on
  the release workstation. Decryption/project check passed. SHA256:
  `F600D659E8F39238C7D6F9D6F6064B87384B132CF772397B6823334E38624A6C`.
- Staging worker image `openbsp-campaign-worker:aa95acb`, revision label
  `aa95acb`, image ID
  `sha256:62d192b6a71d1a2c8a55d6df14af51f92e61869e76fc88c92aabbade5b91c09b`;
  readiness and container health passed on8093. Previous9b92cda image retained.
- Production campaign, chatbot and voice container IDs/start times were
  unchanged; production8094 remained healthy. No Main branch or
  production-policy changes.
- Disposable organization `14014000-0000-4000-8000-000000000001`: **SCRUM-140
  Campaign Policy Test**. Its sender is deliberately disconnected;
  recipients/accounting are labelled mocks. One scheduled job, one daily-budget
  wait, one expired recipient and one cancelled recipient were verified through
  the deployed queue/worker. All four deliveries retained **zero send
  attempts**. The sole enabled policy is in this fixture; other staging
  organizations remain unchanged. No Auth user or email invitation was created
  for this fixture.
- Full backend static/plugin/voice validation passed; initial quota-fixture and
  recovery regression failures were corrected and the complete database suite
  rerun: **61 files / 1,421 assertions passed**. Policy tests:55 locally and in
  a rolled-back staging transaction. Two real concurrent database connections
  reserved only one final slot. Handler13/13; worker16 unit tests plus build.
  Worker broker integration was skipped without a configured local broker;
  deployed staging queue smoke checks above exercised the existing real broker.
- Full frontend validation passed: **468 tests**, generated-type
  synchronization, lint (0 errors,375 warnings), TypeScript and production
  build. No actual Meta template sends were performed.
- Vercel `meta-vista-ui` deployment for310285a succeeded. Authenticated
  visual/manual review is still required: the in-app browser webview did not
  attach during this release. Jira comments could not be posted (current
  connector returned inaccessible/authentication errors); preserve this evidence
  for SCRUM-140.
