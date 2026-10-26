# Organization account setup (SCRUM-130)

The Super Admin onboarding wizard creates an organization and reserves its owner
and initial memberships in one transaction. Login setup is separate: one
person's failure must not roll back the organization or stop another person's
setup.

## Contract

Use the authenticated `organization-provisioning` function with `version: 2`:

- `create`: stable `request_id`, existing organization settings, owner and
  members. Each person has `mode` (`invitation`, `direct`, `pending`); members
  also have a stable `client_key`. Passwords are rejected in this persistent
  creation payload.
- `status`: `provisioning_id`. Returns safe per-person progress derived from the
  existing account-onboarding operations. Invitation accepted for sending does
  not mean the person has completed password setup or joined.
- `continue`: `provisioning_id`, `member_id`, and, for direct creation,
  transient `password` and `confirmed: true`. Processes only that person using
  the shared Team members executor and Auth adapters. Never put this request in
  query-cache mutation variables, persistent drafts, logs or telemetry.

All operations require the existing Super Admin authorization. Account
operations remain bound to the reserved membership and its observed revision.
Setup modes and identities cannot be edited through the wizard after creation;
use Team members for later membership changes. Pending-only mode creates no Auth
user and sends no email.

## Recovery

Reopen the onboarding history record and fetch status before continuing. Skip
completed, invitation-sent and pending-only people. Reuse each person's stable
request/operation ID for failures, expired leases or ambiguous responses. Direct
setup may need password re-entry; passwords are never recoverable from history.
The existing executor checks Auth state before retrying account creation and
must never reset an existing account's password.

Version-1 history and its invitation retry path remain supported. The legacy
provisioning RPC rejects version-2 retry requests, preventing cached old clients
from accidentally sending invitations to pending-only people.

## Validation and rollout

- Focused database checks:
  `npm run db:test -- supabase/tests/organization_account_setup.sql`.
- Focused runtime checks (from `supabase/functions`):
  `deno test -A organization-provisioning/setup_test.ts platform-user-onboarding/core_test.ts`.
- Full repository checks: `npm run validate` in the backend and frontend.
- Back up staging, confirm `acifbsuxmpdtlhbsvhlj`, review `db push --dry-run`,
  apply the generated migration, and deploy `organization-provisioning` and
  `platform-user-onboarding` before the UI.
- In an isolated organization, mix all three modes. Check weak-password
  recovery, continued invitations, direct login, pending-only no Auth/email,
  duplicate creation and history refresh. Complete an invitation from a
  controlled inbox.

Rollback must retain the additive tables and version-2 reservations. Keep the
compatible backend functions available for in-progress setups even if the UI is
reverted. Do not run legacy invitation retries against version-2 records. Main
rollout requires separate approval.
