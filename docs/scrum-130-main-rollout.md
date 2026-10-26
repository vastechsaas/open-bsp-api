# SCRUM-130: approved Main promotion

The user approved promoting Super Admin account setup to Main on 26 October
2026, after completing the staging email invitation, password setup and
dashboard login. The earlier Phase 1/2 documents describe historical
staging-only releases; this record supersedes that release boundary for the
account-setup feature only.

## Scope

- Selectively promote Super Admin Team members, shared account setup and the
  resumable organization wizard. Preserve Main-only changes; do not merge all of
  staging or change Node/Oracle/queue-worker runtimes.
- Hide and disable the pending-only option in the shared dropdown, retaining its
  backend support and existing history. Invitation remains the default.
- Explicitly allow the existing staging callback and Main's
  `https://socialconnect.vastech.biz/onboard/set-password`. The callback must
  still come from protected server configuration, never request input.

## Deployment prerequisites

Confirm Main `buvjopvpkgvzhykwsxnk` and take protected `public`/`auth` schema
and data backups before applying migrations. The approved dry run contains only:

```text
20261020193554_super_admin_team_members.sql
20261020194624_super_admin_team_member_safeguards.sql
20261020200201_team_member_compatibility.sql
20261020200611_team_member_monotonic_revision.sql
20261021185856_platform_user_onboarding.sql
20261021190930_platform_onboarding_recovery_guards.sql
20261026095912_organization_account_setup.sql
```

Use `db push --dry-run --include-all` to review these older prerequisite
migration timestamps; `--include-all` is not authorization to apply any other
migration. Deploy `platform-user-onboarding` and `organization-provisioning`
before the UI.

Main initially has no custom SMTP or setup templates. Email setup must remain
disabled until the administrator approves Main SMTP configuration and it is
verified. Preserve existing Auth policies, redirect entries and fallback email
templates when adding the account-setup branches. Do not reuse staging callback
URLs on Main or silently enable mail delivery.

Set `PLATFORM_ONBOARDING_CALLBACK_URL` to Main's setup callback. Enable
`PLATFORM_ONBOARDING_MAIL_ENABLED` only after approved SMTP/template
configuration; the existing operation ledger, context validation and
session-isolation safeguards remain required. No credentials belong in frontend
variables, Git or this record.

## Validation and recovery

An isolated Main-shaped local database on loopback port 54332 successfully
applied the selected migration chain, without resetting the existing local
database. Generate and synchronize database types from that database, including
`billing`, `public`, `storage`. Run backend and frontend validation against the
Main branches. The local nonstandard database port needs `?sslmode=disable`;
this applies only to the loopback test database, never remote/Main connections.

Check deployed Main route/translations and authoritative RPC authorization.
Treat SMTP acceptance separately from recipient receipt and completed
membership. Do not create or elevate production test administrators merely for
smoke verification.

Rollback UI first if necessary. Keep compatible backend functions, additive
schema and account-operation history available for in-progress invitations.
Never delete Auth users or bypass password/email-conflict checks to recover a
failed setup. A failed person's setup must not remove the organization or
completed work.

## Pre-merge checks

- Full staging backend validation passed: 57 database files, 1,279 assertions.
- Main backend format/lint/type checks, voice tests/build and plugin checks
  passed. The isolated Main database suite passed 54 files on its first run; the
  remaining handoff test counted an unrelated seeded demo message globally.
  Removing that one demo message from the newly created local database made the
  focused handoff rerun pass all 20 assertions (1,234 assertions overall). No
  test assertions or remote data were changed to obtain this result.
- Focused account executor/callback tests passed all 13 cases. Unsupported or
  missing callback configurations remain rejected.
- Main schema/data and Auth-configuration backups completed before deployment,
  outside Git in the protected `scrum-130-main-backup` artifact directory.
- Main frontend tests passed all 424 cases; final type/build checks are recorded
  in Jira with the deployment results rather than assumed here.
