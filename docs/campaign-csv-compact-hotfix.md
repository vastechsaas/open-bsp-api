# Compact campaign log CSV — 10 November 2026

Remove Message content from the downloaded CSV. The columns are Date, Time,
Recipient number, Sender number, Display name and Status. Campaign previews,
delivery outcomes, Owner authorization and export expiry are unchanged.

Project each bounded private CSV part into six columns at download time. This
also fixes files already generated before the patch, without deleting exports or
requiring a new snapshot. Handle quoted commas, escaped quotes and embedded
carousel newlines; never split records on newlines alone. Reject malformed parts
rather than shift fields or silently omit rows.

Keep the private seven-column writer unchanged for a rolling-compatible patch:
old workers can still read every generated part, and new download workers remove
the content column. Internal snapshots/parts still expire after 24 hours.

No database migration, generated-type change, frontend build, standalone worker
deployment or staging CLI access is required. Deploy only the two changed export
modules to Oracle after backing them up. Sync the same patch to Main and staging
source branches. No campaign messages are sent by this patch or its tests.

Validation: six focused CSV/worker tests, the endpoint type check and full
backend validation with `--skip-db` passed. Oracle's authenticated processor
returned HTTP 200 with `csv_columns: 6`, confirming the refreshed worker loaded
the patch.

Only `csv.ts` and `index.ts` were deployed. Their previous versions are retained
at `/home/ubuntu/wababase/backups/campaign-csv-compact-20261109T204049Z/`. No
service restarted and no staging CLI commands were used. Download the CSV again;
previously imported spreadsheet files do not change automatically.
