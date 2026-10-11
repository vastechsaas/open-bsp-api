# Messages availability control

The Messages header uses the former organization-title space for an accessible
Available/Away switch. Available is green with its white thumb on the right;
Away is red with the thumb on the left. Labels stay visible in narrow layouts.
The organization selector elsewhere in the application is unchanged.

Accepted Agents and Supervisors can read, change and heartbeat their own
organization-scoped availability through the existing three presence RPCs.
Pending/rejected invitations and unrelated organizations are not authorized.
Owners/admins are not newly enrolled. Existing 30-second heartbeat and
two-minute freshness rules remain unchanged.

This change does not add Supervisors to routing queues or Round Robin selection,
change business-hours eligibility calculations, change takeover permissions or
automatically assign conversations. Supervisor availability records personal
presence; existing agent-only automated assignment rules remain in place.

Deploy the generated `20261011184531_supervisor_assignment_presence.sql`
migration before the UI. It only replaces function bodies; RPC arguments, return
types, grants and database records are unchanged. The known unrelated
table-grant revokes emitted by the schema diff were removed before local apply.
No Node/PHP/integration-worker deployment is needed.

The switch retains the last confirmed state during a save, disables repeated
clicks, and shows a Retry action on a request failure. An initial loading/error
state is not presented as a confirmed Away status. All new copy is translated
into the application's existing supported locales.

## Validation and release

- Backend feature commit: `1246a4a` on `meta_vista_backend`; focused Main
  cherry-pick: `5894ea4`.
- Frontend feature commit: `ddf281d` on `meta_vista_frontend`; focused Main
  cherry-pick: `8ebd9d8`. Unrelated staging features were not merged to Main.
- Backend full validation passed, including 49 database test files and 1,039
  assertions. The new supervisor presence regression contains 16 assertions.
- Frontend full validation passed: 376 tests, generated-type synchronization,
  TypeScript and production build. Main's focused nine tests and production
  build also passed after cherry-picking.
- Main's schema and data backups were completed before applying the migration,
  under `.codex/backups/messages-availability-20261011/` on the deployment
  workstation. Backup data is private and is not committed.
- Main's migration application was confirmed in remote migration history.
  Staging's Supabase Git integration reported success before the UI release.
- A pre-existing formatting-only failure in `docs/shared-handoff-messages.md`
  was corrected without changing its content or runtime behavior.
- No live agent's availability or conversation was changed during validation.
  Account-level interaction testing remains a post-release check.
