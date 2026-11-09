# Completed campaign CSV export

## Scope and access

Owner-only action beside existing campaign Activity, only for `completed`
campaigns. Activity and dispatch permissions are unchanged. No sends or campaign
worker changes. Main/Oracle rollout was separately approved on 10 November 2026.

Exports use authenticated, accepted organization Owner membership and an active
organization. Platform-admin status alone and organization API keys do not grant
access. Request, status, retry, ticket issuance and download consumption all
enforce authorization. No direct snapshot-table or Storage access is granted.

CSV columns: Date, Time, Message content, Recipient number, Sender number,
Display name, Status. Delivered means delivered/read evidence; Not Delivered
means definitive dispatch/receipt failure without delivered/read evidence.
Acceptance, cancellation, expiry and uncertainty stay blank. No failure reasons,
credentials, media bytes or temporary image URLs are exported.

Date/time uses the saved campaign timezone, displayed next to the action. Prefer
the latest recorded submission time, otherwise the existing submission activity
timestamp; missing historical times remain blank. Sender metadata is the
available account profile at snapshot time, not a claim of historical branding.
Content resolves saved template text, ordered carousel cards and website links
using the existing personalization renderer. Unavailable historical content is
not invented.

## Background processing and download

- `request_campaign_log_export`: stable request UUID, one active job per
  Owner/campaign, transactionally frozen recipient/receipt snapshot.
- `get_campaign_log_export`: latest unexpired authoritative progress for that
  Owner/campaign; safe metadata only.
- `retry_campaign_log_export`: resumes failed preparation without changing its
  snapshot or duplicating finished rows.
- `campaign-log-export`: service-authenticated scheduled Edge Function; 100 rows
  per deterministic private file, 60-second fenced leases, three consecutive
  failures before manual Retry. No customer data is logged.
- `issue_campaign_log_download`: one-use 256-bit ticket, stored hashed, valid
  for one minute. Native browser form POSTs the ticket (not a session JWT) to
  `/functions/v1/campaign-log-export/download`. The endpoint rechecks current
  Owner membership and streams ordered parts; the browser does not buffer a full
  CSV Blob. Each ticket is consumed once, even when access was revoked.
- UTF-8 BOM, quoted CSV fields and formula-injection protection apply. Unknown
  recipient results remain in the file with a blank Status.
- Snapshots/files expire after 24 hours. The minute cron removes bounded
  batches, including orphaned files after campaign/organization deletion.
  Cleanup may take multiple ticks for large exports; expired files cannot be
  newly downloaded.

Generate updated CSV creates a new as-of snapshot after the previous job
finished. Late receipts never change an already generated file. Storage/network
failures do not change delivery outcomes or dispatch retries.

## Deployment and rollback

Branches: `codex/completed-campaign-csv-backend` and
`codex/completed-campaign-csv-ui`, based on the respective staging branches.

1. Confirm staging `acifbsuxmpdtlhbsvhlj` and back up before deployment.
2. Deploy only the new `campaign-log-export` function and additive migration.
   The migration includes explicit function ACLs, the private bucket and minute
   cron using existing Vault `edge_functions_url` / `edge_functions_token`.
3. Deploy dependent UI after backend checks. No new secrets or external service.
4. Run
   `node scripts/test-campaign-export-staging.mjs --create-isolated-fixture`. It
   uses synthetic data, verifies 601-recipient streaming and authorization,
   sends no templates and archives its isolated organization afterward.
5. Roll back UI first and unschedule only `campaign-log-exports-every-minute` if
   necessary. Retain additive tables until temporary jobs/files are cleaned up.
   Never reset or resend campaign deliveries.

Migration generated from schema sources. Known unrelated grant-revoke noise was
trimmed before local application. Explicit function ACLs and bucket/cron data
definitions were included because schema diff does not preserve those records.

## Validation and staging evidence

- Local generated migration applied successfully; type generation synchronized
  `billing`, `public`, and `storage` to the UI once.
- Focused export database suite: 41 checks passed; CSV/worker: 4 tests passed.
- Full backend validation: 65 database suites / 1,562 checks passed, plus Deno
  lint/type checking, plugin and voice-service validation.
- Staging reference verified; dry-run lists only migration
  `20261109192334_completed_campaign_log_exports.sql`.
- Predeployment public schema/data backup secured outside the repository at
  `C:/Users/Hurera Mujeeb/.codex/backups/campaign-csv-staging-20261110/`.
- Full UI validation passed: 490 tests, synchronized database types, ESLint with
  zero errors, TypeScript and production Vite build. Existing unrelated lint
  warnings remain. Focused UI tests/format checks also passed after final
  polish.
- Backend implementation commit `0420635`; UI commit `dbeea7e`. Backend staging
  merged/deployed before the dependent UI. Main refs remain unchanged.
- Staging smoke passed: organization `c79b30ec-825b-4a66-8ad6-44282c047b81`,
  campaign `c53943e7-08a5-472e-9982-0b085f343252`, export
  `879f156e-220f-4641-990d-9e063170e308`: 601 rows, 1 Delivered, 2 Not
  Delivered, 598 blank. Native form POST streamed the complete CSV; replay and
  revoked-role requests were denied; direct snapshot reads were denied. No
  templates sent.
- The successful synthetic fixture was archived after verification. Its private
  export evidence expires automatically after 24 hours. Two earlier
  smoke-harness setup failures were corrected; no production campaign data was
  affected.
- All synthetic smoke organizations, including the empty failed-setup fixture,
  were archived using the existing lifecycle operation. No customer data
  deleted.
- Backend staging head `4c7afe0`; UI staging head `dbeea7e`. The dependent UI
  was pushed after the smoke passed. Vercel `meta-vista-ui` deployment
  `GMEvXnvpJxoMhFY3cxcUyxQkS7KB` succeeded for that UI commit.

## Main and Oracle rollout — 10 November 2026 (Pakistan)

- Selectively ported the export commits onto Main; staging-only Pause/Resume
  fields, permissions and UI were not merged. Generated and synchronized types
  from a disposable database built from Main migrations: only 206 export lines
  were added, with no existing Main types removed.
- Main-schema export database tests: all 41 passed. Focused UI permission/state
  tests and database-type synchronization passed; production build checked.
- Live Oracle backup verified with `pg_restore --list`:
  `/home/ubuntu/wababase/backups/campaign-csv-main-20261109T200145Z/database-before.dump`.
- Applied the additive export migration transactionally and deployed only the
  new export function directory. Existing media URL hotfix, chatbot/campaign
  workers, credentials and connections were preserved; no containers restarted.
- Restored the already-preloaded `pg_cron` extension, declared by the existing
  schema sources but missing from the restored database. No PostgreSQL restart
  or other background jobs were enabled; the export job is the sole cron entry.
- Oracle verification: anonymous processor requests return 401, invalid native
  download tickets return 403, service-authenticated idle processing returns
  200, private bucket remains non-public. Scheduled executions and their HTTP
  responses both succeed (200). No campaign messages were sent.
- Main release branches: `codex/completed-campaign-csv-main-backend` and
  `codex/completed-campaign-csv-main-ui`. Frontend publication follows backend
  verification; final deployment evidence is recorded below.
