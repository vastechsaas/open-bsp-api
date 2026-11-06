# Reuse Meta carousel media IDs

Scope: Main's existing campaign sending paths, both CloudAMQP and legacy
PostgreSQL. No customer test sends, UI controls, chatbot/Oracle deployment,
campaign restarts, history changes or deletion of original images.

## Behavior

- A private cache is keyed by organization, sending number and the immutable
  storage URI. Media IDs cannot be supplied by tenant clients.
- Cache misses download/validate the original and upload it to Meta once.
- Hits validate the cached ID using Meta metadata only. Image bytes are not
  downloaded or uploaded for each recipient. Metadata calls still use compute
  and API requests; this optimization does not eliminate all processing.
- Re-upload only on a definitive missing-object metadata response (404/410, or
  Graph 100/subcode 33). Authentication failures, outages and rate limits do not
  invalidate the cache or cause repeated uploads.
- Two-minute upload leases serialize concurrent misses. Expired workers cannot
  commit or release a newer worker's lease. Upload requests time out after one
  minute; a competing preparer waits at most 20 seconds before the job's normal
  retry handling takes over. A crash may leave an unused Meta upload, but never
  causes a customer message to be retried by this cache.
- Sending authorization, budgets, recipient attempts, accepted/uncertain
  outcomes and receipt processing remain unchanged. This module only prepares
  images and never calls the message-sending endpoint.
- Original storage files remain available for drafts, recovery and history.
  Standard template header media already uses saved Meta IDs and is unchanged.

## Validation and delivery

- Deno tests: persistent reuse across independent preparations; expired-image
  replacement; transient metadata failures; bounded contention; stale leases;
  unchanged carousel card ordering and no repeated image-byte transfers.
- SQL tests: cache identity isolation, compare-and-swap invalidation, crash
  recovery, connected-account guards and backend-only access.
- Generate one migration from schema sources. Trim only known generator grant
  noise and preserve explicit worker-only grants before applying locally.
- Apply to a Main-compatible isolated local database; regenerate and mirror
  database types. Run backend and type-sync checks before committing.
- Confirm Main project `buvjopvpkgvzhykwsxnk`, back up the previous deployed
  functions and relevant definitions, and review the migration dry run.
- Apply the additive migration before deploying campaign-dispatch and
  campaign-worker. Never trigger a claimant as a health check.
- No real campaign/template sends are permitted for validation. Existing
  authorized campaigns remain governed by their existing schedule and limits.

## Rollback

Restore the backed-up function versions if necessary. Keep the additive cache
table/data and original images. Do not reset delivery attempts, restart
campaigns or resend accepted/uncertain submissions. Rollback may restore the
old, more expensive image preparation but must not change send outcomes.

## Evidence

- Forty-two focused Deno tests passed, including a two-card/26-preparation
  scenario that downloads/uploads only two originals. Replacing one expired ID
  transfers only that image; a simulated Meta outage transfers neither.
- Full backend validation passed: formatting, lint/type checks, voice-service
  tests/lint/build, plugin checks, and 1,496 database assertions in 63 files.
- Main-compatible isolated local migration passed; 28 cache-specific database
  assertions cover worker-only grants and concurrency/tenant boundaries.
- Database types regenerated once and mirrored into the frontend types branch.
- Main dry run includes only `20261106212252_campaign_meta_media_reuse.sql`. The
  generated, unapplied migration's 238 unrelated grant revokes were trimmed and
  explicit worker-only ACLs retained before any local/remote application.
- Previous campaign function sources and the Main public/billing schema are
  backed up outside Git in `.codex/backups/campaign-media-reuse-main-20261107`.
- Main backend commit: `b1786b3`. Migration applied; campaign-dispatch v6 and
  campaign-worker v22 are ACTIVE. No Oracle worker/container changes were
  needed.
- Live no-send GET probes: unauthenticated calls return 401; authenticated
  campaign-worker GET returns 405 and a nonexistent dispatch job returns 404. No
  campaign claimant, image upload or customer send was invoked by smoke tests.
- Main cache RLS is enabled; authenticated users cannot read/claim the cache,
  anonymous users cannot commit IDs, and service-role coordination is allowed.
- Initial cache is empty; it populates during subsequent authorized campaign
  processing. No backfill, restart or resend is needed. Production bandwidth
  savings have not yet been measured.
- Frontend type-only sync merged to Main as `9281257`: all 470 tests, database
  type synchronization, TypeScript and production build passed. Lint has only
  the existing warning baseline; no functional UI controls changed.
- Staging and the separate self-hosted Supabase instance were not modified.
- GitHub's backend `check` passed for `b1786b3`. The separate Supabase Preview
  check reports `failed to bundle function: exit status 10`; the preceding Main
  commit `35816ef` has the identical failure. This pre-existing integration
  issue did not prevent the explicit, verified deployment of both campaign
  functions.
