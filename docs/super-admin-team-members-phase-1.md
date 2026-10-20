# Super Admin organization Team members — Phase 1

## Scope

The existing `/platform/$organizationId/agents` route becomes **Team members**.
Super Admins can create pending memberships and manage Owner, Supervisor and
Agent organization access. Existing Administrator and Member rows are visible
but read-only. Tenant-side role selectors are unchanged.

This does **not** create Auth users, set passwords, send invitations by email,
delete global accounts, or manage platform Super Admin privileges.

Branches:

- Backend: `codex/super-admin-team-members-backend` (from staging).
- Frontend: `codex/super-admin-team-members-ui` (from staging).
- Main and Node are not included in this release.

## Contracts

- `list_platform_organization_members_page(organization_id, page, page_size, search)`:
  human pending/accepted members, roles, queue names/IDs and total count. Search
  and organization authorization run before pagination; page size is capped
  at 50.
- `create_platform_organization_member_invitation`: normalized email, chosen
  role, stable request ID. Existing Auth users are linked without automatic
  acceptance.
- `update_platform_organization_member`: member ID, name, role, queue IDs,
  original `updated_at` token and stable request ID. Email is not editable.
- `remove_platform_organization_member`: original token and stable request ID;
  removes only that organization membership.

All public entry points require `require_platform_admin()`. Legacy Agent-only
RPC signatures remain and delegate to the same private mutation implementation.
Private mutation/lock helpers are not executable by authenticated clients.

## Safety

- Administrator/Member and AI rows cannot be changed using the new endpoints.
- Normalized same-organization duplicate emails are rejected across roles.
- Pending and accepted Agents/Supervisors count toward existing capacity limits.
- Only accepted human Agents can join queues. Leaving Agent clears queues;
  changing role resets availability to Away.
- A shared transaction lock fences member changes, assignments, pending human
  sends, lifecycle reservations and queue membership changes.
- Role changes/removal reject active assignments, unresolved outgoing sends and
  nonterminal lifecycle operations. Name-only changes remain possible.
- Queue removal rejects active assignments using that queue. Queue edits also
  advance the member token, preventing another screen from overwriting them.
- The last accepted Owner cannot be removed/demoted. Pending invitations do not
  replace an accepted Owner. Concurrent owner mutations are serialized.
- Audit events retain before/after role and queue state, removed identity,
  acting Super Admin and canonical request parameters. Retries do not duplicate
  effects or audit events; changed payloads cannot reuse a request ID.
- Auth records, other organizations, conversations and messages are preserved.
  Message sender foreign keys may become null under the existing FK behavior;
  removal attribution is retained in the platform audit record.
- Existing private permission broadcasts refresh tenant roles, organizations,
  invitations, queues and presence. Every server action still reauthorizes.

## Local verification

```powershell
npm run db:test -- supabase/tests/platform_team_members.sql
npm run db:test -- supabase/tests/platform_agent_management.sql
node scripts/test-team-member-concurrency.mjs
npm run validate:quick
npm run validate
```

The concurrency script targets **only the local Docker database** and cleans up
its exact disposable fixture IDs. It checks concurrent Owner removal/demotion
and both orders of assignment versus removal.

Frontend validation must point `API_DB_TYPES_FILE` to this backend worktree's
generated `supabase/functions/_shared/db_types.ts`, then run `npm run validate`.

Schema sources are authoritative. Generated local diff batches are retained:
`20261020193554_super_admin_team_members` and
`20261020194624_super_admin_team_member_safeguards`, followed by
`20261020200201_team_member_compatibility` and
`20261020200611_team_member_monotonic_revision`. The follow-ups correct the
existing Owner update trigger, preserve permission-error behavior and add
cross-screen, monotonic queue revision safeguards discovered during regression
testing. The local batches were already applied, so they are retained rather
than rewriting applied migration history. Known spurious table-revoke noise was
removed; private/public function ACLs are explicit because the diff tool omits
those grants. No deployed migration was changed. Apply all four in timestamp
order.

## Staging rollout

1. Confirm access to **acifbsuxmpdtlhbsvhlj**; do not use Main
   **buvjopvpkgvzhykwsxnk**. The implementation checkout was initially linked to
   Main, so linking must be explicitly verified before any remote command.
2. Retain a secure staging schema/data backup and record its location outside
   Git.
3. Inspect remote migration history and `supabase db push --dry-run`. Stop for
   unrelated pending migrations or unexpected changes.
4. Apply backend migrations before exposing the dependent UI. Confirm the RPCs
   and authenticated-only execution permissions.
5. Merge backend and then frontend into their staging branches and let
   configured deployment workflows complete. Do not merge into Main.
6. In a disposable staging organization verify: all roles listed, manageable
   role creation/edit/cancellation/removal, last-owner/capacity checks, Agent
   queues, stale updates and tenant permission refresh. Confirm no Auth
   user/email was created and another organization retains its membership.

No staging verification or deployment should be claimed until CLI access,
backup, migrations and the browser checks above have actually succeeded.

## Verification record — 2026-10-21

- Backend full validation: passed; 52 database files / 1,151 assertions.
- Team-specific database coverage: 54 assertions passed.
- Local concurrency script: all three race scenarios passed and fixtures
  removed.
- Frontend: 419 tests passed; full lint had no errors. After correcting a
  query-key inference error, TypeScript and the production build passed.
  Existing lint warnings outside this feature remain unchanged.
- Generated database types match across the backend and frontend worktrees.
- Staging CLI access and the linked project were verified as
  `acifbsuxmpdtlhbsvhlj`. Schema and data backups are outside Git under
  `C:/Users/Hurera Mujeeb/.codex/backups/staging-team-members-20261021/`.
- The staging dry run contains only the four feature migrations listed above.
- Remote rollout and browser verification are recorded separately after
  execution.
