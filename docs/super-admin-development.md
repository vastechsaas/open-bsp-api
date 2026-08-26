# Super Admin development

- **Status:** Phase 6 Round Robin auto-assignment in development
- **Last updated:** 2026-08-26
- **Audience:** Internal platform builders
- **Backend branch:** `scrum-113-auto-assignment-backend`
- **Frontend branch:** `scrum-113-auto-assignment-ui`

## Purpose

This document tracks the iterative delivery of the platform-level Super Admin
workspace. Super Admins are trusted internal operators who can inspect every
tenant without becoming members of those organizations or impersonating tenant
users.

The platform workspace reuses existing product UI and domain data while keeping
platform authorization separate from the organization roles `owner`, `admin`,
`supervisor`, `member`, and `agent`.

## Locked decisions

- Super Admin access is stored in a protected database allowlist keyed by the
  authenticated Supabase user ID.
- Active Super Admins land on `/platform` after login and may explicitly enter
  their ordinary tenant workspace.
- The platform tenant selector uses URL-backed scope and never overwrites the
  tenant workspace's `activeOrgId`.
- **All tenants** is the default platform scope.
- The foundation is read-only and records global and tenant access events.
- Existing tenant mutation permissions are not expanded for Super Admins.
- Initial Super Admin accounts are provisioned through a trusted database
  operation. Emails are never hardcoded in migrations.
- Platform lists use server-side pagination, search, deterministic ordering, and
  page sizes of 10, 25, or 50.

## Roadmap

| Phase | Deliverable                       | Status      | Exit criteria                                                                                                                                  |
| ----- | --------------------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Foundation and tenant selector    | Complete    | Authorized builders can open the global overview, search/select a tenant, view its operational summary, and produce an access audit event.     |
| 2     | Monthly tenant reports            | Complete    | A Platform Admin can select one tenant and download live monthly conversation and campaign CSV reports using UTC boundaries.                   |
| 3     | Selected organization management  | Complete    | The global tenant selector opens a reusable detail shell where Platform Admins can inspect the tenant and manage routing queues with auditing. |
| 4     | Selected-tenant WABA Health       | Complete    | Platform Admins can diagnose each tenant WhatsApp account and run protected, audited health, profile-refresh, and template-sync actions.       |
| 5     | Agent management and capacity     | In progress | Platform Admins can configure tenant Agent capacity and manage pending/accepted Agents through protected, audited operations.                  |
| 6     | Round Robin auto-assignment       | In progress | Routed Pending conversations are assigned atomically to available queue-member Agents with history, notifications, and recovery.               |
| 7     | Read-only tenant modules          | Planned     | Contacts, Conversations, and other tenant modules reuse presentation components with explicit platform-scoped data adapters.                   |
| 8     | Additional administrative actions | Planned     | Individually approved platform actions have explicit permissions, confirmation, audit history, and rollback/error behavior.                    |

## Phase 6 — Round Robin auto-assignment

- **Jira:** SCRUM-113
- **Migration:** `20260826111651_scrum_113_auto_assignment.sql`
- Organization automation and new queues remain disabled/manual by default.
- Eligible Agents explicitly select Available and maintain a 30-second
  heartbeat; eligibility expires after two minutes without changing existing
  assignments.
- The database resolver locks each conversation and queue cursor, assigns only
  accepted available queue members, and atomically records history, a timeline
  event, and a notification.
- Chatbot handoff, queue transfer, manual unassignment, setting changes, Agent
  availability, and a one-minute recovery job all use the same resolver.
- Capacity, least-loaded/weighted strategies, schedules, skills, fallbacks,
  offline redistribution, reopen policy, analytics, and SLA escalation remain
  deferred.

## Phase 1 — Foundation and tenant selector

### Backend checklist

- [x] Add protected `platform_admins` storage with active/revoked state.
- [x] Add append-only, idempotent platform access events.
- [x] Add platform authorization and read-only overview RPCs.
- [x] Add paginated organization search and operational summaries.
- [x] Keep existing organization RLS and write permissions unchanged.
- [x] Generate and apply the migration locally.
- [x] Regenerate backend and frontend database types.
- [x] Pass focused database tests and full backend validation.

### Frontend checklist

- [x] Add the `/platform` layout and access guard.
- [x] Add automatic platform landing after login.
- [x] Add the global overview and paginated organization table.
- [x] Add the asynchronous tenant selector and selected-tenant summary.
- [x] Prevent stale data from appearing while tenant scope changes.
- [x] Skip ordinary tenant initialization and realtime work in platform mode.
- [x] Record one idempotent access event per route entry.
- [x] Pass focused frontend tests, build, lint, and full tests.

### Acceptance scenario

1. An active allowlisted builder signs in and lands on `/platform`.
2. The global overview shows aggregate operational totals and a searchable,
   paginated organization table.
3. Selecting Tenant A opens `/platform/<tenant-a-id>`, displays Tenant A only,
   and records the access.
4. Switching to Tenant B shows a fresh loading state before Tenant B data and
   never flashes Tenant A data.
5. **All tenants** returns to `/platform` and records the global access scope.
6. A normal tenant user cannot open platform routes or call platform RPCs.
7. Revoking the builder's allowlist entry blocks their next platform request.
8. The builder can explicitly enter the ordinary tenant workspace without
   changing platform authorization or impersonating another user.

The complete scenario passed on staging on 2026-08-11, including automatic
landing, Tenant A/Tenant B switching without stale content, URL restoration,
audit recording, revocation, and reactivation.

## Phase 2 — Monthly tenant reports

### Locked decisions

- Reports are generated for one selected tenant at a time.
- V1 exports CSV only and uses UTC calendar-month boundaries.
- Reports are recalculated from live data and are not stored as snapshots.
- The conversation report includes conversations with incoming or outgoing
  message activity in the selected month. Internal notes are excluded.
- The campaign report includes launched campaigns whose delivery snapshot was
  created in the selected month. Draft campaigns are excluded.
- Customer name and channel address are included in the conversation export.
- Current conversation status and assignment reflect generation time.
- Template-message reports, scheduled exports, Excel/PDF, and combined
  all-tenant reports remain deferred.

### Backend checklist

- [x] Add protected, append-only report export audit events.
- [x] Add Platform Admin-only monthly conversation and campaign report RPCs.
- [x] Add the authenticated CSV export Edge Function.
- [x] Generate/apply the migration and regenerate backend/frontend types.
- [x] Pass focused reporting tests, the full database suite, and targeted Edge
      Function checks.

### Frontend checklist

- [x] Add the selected-tenant Reports navigation and route.
- [x] Add the UTC month selector and conversation/campaign download cards.
- [x] Cancel downloads when tenant context changes.
- [x] Show progress, empty, and error feedback without storing report files.
- [x] Pass focused reporting tests and one full frontend validation.

### Acceptance scenario

1. A Platform Admin selects Tenant A and the previous UTC month.
2. The conversation CSV contains only Tenant A conversations with external
   message activity during that month.
3. The campaign CSV contains only Tenant A campaigns launched during that month
   and reports delivery counts from the delivery rows.
4. A month with no data returns a valid header-only CSV.
5. Switching to Tenant B cancels any Tenant A download and never leaks Tenant A
   data into the new scope.
6. A normal tenant user and a revoked Platform Admin cannot call reporting RPCs
   or the export endpoint.
7. Each successful export records one idempotent audit event.

## Phase 3 — Selected organization management

### Locked decisions

- The existing searchable tenant dropdown is the only organization selector; no
  separate Organizations table or route is added.
- Selecting a tenant opens `/platform/<organization-id>` and exposes Overview,
  Queues, Agents, and Reports within one organization-detail shell.
- Organization setup state is derived from connected WhatsApp accounts; no
  organization suspension lifecycle is introduced.
- Routing queues remain manual-assignment queues. Round robin and other
  automatic assignment strategies remain deferred.
- Platform Admin queue mutations are atomic, idempotent, and append-only audited
  without granting tenant organization roles.
- The Agents tab is read-only; queue membership changes happen from Queues.

### Checklist

- [x] Remove the duplicate organization table from Platform Overview.
- [x] Add the selected-organization detail shell and navigation.
- [x] Add Platform Admin queue and accepted-Agent list RPCs.
- [x] Add audited Platform Admin queue create/update/archive/member operations.
- [x] Reuse the tenant queue presentation without coupling platform scope to
      `activeOrgId`.
- [x] Add the read-only Agents tab with queue memberships.
- [x] Generate/apply the migration and synchronize database types.
- [x] Pass focused and final backend/frontend validation.
- [x] Merge backend staging before frontend staging and smoke-test tenant
      switching and queue management.

## Phase 4 — Selected-tenant WABA Health

### Locked decisions

- V1 is selected-tenant only and shows connected and disconnected WhatsApp
  accounts.
- Cached health is refreshed when missing or older than five minutes; no cron,
  alerts, global health overview, or reconnect flow is included.
- Health states are Healthy, Warning, Disconnected, and Unknown. Lack of message
  activity alone never makes an integration unhealthy.
- Webhook operational errors use a rolling 24-hour window.
- Platform APIs never return Meta access tokens, verify tokens, or raw sensitive
  error payloads.

### Checklist

- [x] Add protected WhatsApp health snapshots and webhook heartbeats.
- [x] Add Platform Admin-only paginated health and account-detail RPCs.
- [x] Add audited Test Connection, Refresh Account, and Re-sync Templates
      actions.
- [x] Add the flat WABA Health list and account-detail routes.
- [x] Generate/apply the migration and synchronize database types.
- [x] Pass focused and final backend/frontend validation.
- [x] Merge backend staging before frontend staging and smoke-test health
      states.

The staging smoke test passed on 2026-08-14. Hamza_WABA automatically refreshed
from Unknown to Healthy, the account detail and audited Test Connection action
worked, Staging Test Organization displayed a Disconnected account, tenant
switching preserved the WABA Health route, and the status filter returned the
correct empty state. No live tenant currently has a Warning account, so Warning
rendering and precedence remain covered by the passing backend/frontend tests
rather than fabricated staging data.

## Phase 5 — Agent management and capacity

### Locked decisions

- Capacity is unlimited until a Platform Admin configures a positive limit.
- Accepted and pending human Agents and Supervisors consume capacity; the
  management table itself lists Agents only.
- Invitations reuse the existing pending membership flow and reserve capacity.
- Platform Admins may edit Agent names and, after acceptance, routing-queue
  memberships. They cannot edit email, role, password, or authentication users.
- Lowering capacity below current usage is allowed and blocks additional
  capacity-consuming invitations until usage falls below the limit.

### Checklist

- [x] Add protected tenant Agent-capacity storage and shared concurrent-write
      enforcement.
- [x] Add Platform Admin capacity, invite, edit, remove, and paginated Agent
      interfaces with idempotent auditing.
- [x] Add focused database coverage for capacity, authorization, invitations,
      queue membership, removal, and audit state.
- [ ] Synchronize database types and complete backend validation.
- [ ] Add the Platform Agent management table, capacity state, and dialogs.
- [ ] Complete frontend validation, merge backend before frontend, and verify
      the DKR five-seat scenario on staging.

## Delivery log

| Date       | Phase | Repository | Branch / commit                               | Migration                                                          | Validation                                                       | Environment | Notes                                                                                                                                |
| ---------- | ----- | ---------- | --------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 2026-08-10 | 1     | Backend    | `super-admin-foundation-backend` / `4a8fe3a`  | `20260810175925_super_admin_foundation.sql`                        | Focused 35/35; full 498/498                                      | Local       | Schema, RPCs, RLS, audit storage, migration, and generated types pass.                                                               |
| 2026-08-10 | 1     | Frontend   | `super-admin-foundation-ui` / `23b1be1`       | n/a                                                                | Focused 14/14; full 171/171; lint and build pass                 | Local       | Platform routes, tenant selector, summaries, and access auditing pass.                                                               |
| 2026-08-10 | 1     | Backend    | `meta_vista_backend` / `fd31cc3`              | Applied remotely                                                   | Remote migration verified                                        | Staging     | Initial builder provisioned; revocation and reactivation verified.                                                                   |
| 2026-08-11 | 1     | Frontend   | `meta_vista_frontend` / `8f2af13`             | n/a                                                                | Browser acceptance scenario passed                               | Staging     | Added a loading guard so tenant switches never flash the old scope.                                                                  |
| 2026-08-11 | 2     | Backend    | `super-admin-reporting-backend` / `2457718`   | `20260811160347_platform_admin_reporting.sql`                      | Focused 20/20; full DB 518/518; CSV 3/3; Edge check passed       | Local       | Repository Deno validation was blocked by an external `esm.sh` 408; the new function passed against the same pinned npm package.     |
| 2026-08-11 | 2     | Frontend   | `super-admin-reporting-ui` / `f7f1312`        | n/a                                                                | Focused 8/8; full 179/179; types, lint and build pass            | Local       | Tenant route, UTC month selection, cancellation, and CSV states pass.                                                                |
| 2026-08-11 | 2     | Backend    | `meta_vista_backend` / `d4a2d43`              | Applied by staging deployment                                      | Export endpoint returned authenticated CSV successfully          | Staging     | Tenant A July conversation export returned 6 rows; audit recording completed.                                                        |
| 2026-08-11 | 2     | Frontend   | `meta_vista_frontend` / `06e6275`             | n/a                                                                | Browser smoke test passed                                        | Staging     | Tenant B June campaign export returned a valid empty CSV; tenant routing, UTC selector, and readable labels verified.                |
| 2026-08-13 | 3     | Backend    | `scrum-109-super-admin-organization-backend`  | `20260812161816_scrum_109_super_admin_organization_management.sql` | Focused 13/13; full DB 555/555; Deno lint/check pass             | Local       | Platform queue authorization, tenant isolation, membership validation, idempotent mutations, and audit history pass.                 |
| 2026-08-13 | 3     | Frontend   | `scrum-109-super-admin-organization-ui`       | n/a                                                                | Focused 6/6; full 197/197; types, lint and production build pass | Local       | Global selector, organization shell, queue management, read-only Agents, shared editor, and nested Reports pass.                     |
| 2026-08-13 | 3     | Backend    | `meta_vista_backend` / `c31201e`              | Applied by staging deployment                                      | Platform queue and Agent RPCs loaded successfully                | Staging     | Backend was merged before frontend; protected queue lists and tenant summary are available.                                          |
| 2026-08-13 | 3     | Frontend   | `meta_vista_frontend` / `404a9d5`             | n/a                                                                | Browser smoke test passed                                        | Staging     | The global selector opened Hamza_WABA; Overview, Queues, Agents, and Reports loaded in one tenant detail shell.                      |
| 2026-08-14 | 4     | Backend    | `super-admin-waba-health-backend` / `05c0b46` | `20260813210246_super_admin_waba_health.sql`                       | Focused 24/24; quick and full validation pass                    | Local       | Health snapshots, webhook heartbeat, protected RPCs, audited actions, and synchronized database types pass.                          |
| 2026-08-14 | 4     | Frontend   | `super-admin-waba-health-ui` / `d81c145`      | n/a                                                                | Focused 7/7; full 205/205; types, lint, and build pass           | Local       | Flat health list/detail routes, status filtering, three-action concurrency, cancellation, and translations pass.                     |
| 2026-08-14 | 4     | Backend    | `meta_vista_backend` / `05c0b46`              | Applied by staging deployment                                      | Protected RPCs and authenticated action endpoint succeeded       | Staging     | Backend deployed before frontend; cached health and manual connection checks updated the live snapshot.                              |
| 2026-08-14 | 4     | Frontend   | `meta_vista_frontend` / `d81c145`             | n/a                                                                | Browser smoke test passed                                        | Staging     | Healthy and Disconnected accounts, detail sections, actions, filtering, and tenant switching passed; no live Warning fixture exists. |

## Deferred

- Tenant mutations other than the explicitly audited routing-queue actions.
- Impersonating tenant users.
- Super Admin invitation or management UI.
- Template-message reporting, stored report snapshots, scheduled exports, and
  combined all-tenant reports.
- Billing, quota, integration, assignment, or organization mutations.
- Read-only reuse of full tenant modules beyond the Phase 1 summary.

## Update rules

- Update status when a phase starts, reaches staging, or is completed.
- Record branches, commits, migration names, validation commands, staging
  results, and caveats in the delivery log.
- Mark a phase complete only after its acceptance scenario passes on staging.
- Record newly approved behavior before implementation so later phases do not
  rely on undocumented assumptions.
