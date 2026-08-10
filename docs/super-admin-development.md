# Super Admin development

- **Status:** Phase 1 in progress
- **Last updated:** 2026-08-10
- **Audience:** Internal platform builders
- **Backend branch:** `super-admin-foundation-backend`
- **Frontend branch:** `super-admin-foundation-ui`

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
- Platform lists use server-side pagination, search, deterministic ordering,
  and page sizes of 10, 25, or 50.

## Roadmap

| Phase | Deliverable | Status | Exit criteria |
| --- | --- | --- | --- |
| 1 | Foundation and tenant selector | In progress | Authorized builders can open the global overview, search/select a tenant, view its operational summary, and produce an access audit event. |
| 2 | Read-only tenant modules | Planned | Dashboard, Contacts, Team, Conversations, and Integrations reuse existing presentation components with explicit platform-scoped data adapters. |
| 3 | Global and tenant reports | Planned | Reports are generated server-side for all tenants or one selected tenant and can be exported without client-side tenant loops. |
| 4 | Administrative actions | Planned | Individually approved platform actions have explicit permissions, confirmation, audit history, and rollback/error behavior. |

## Phase 1 — Foundation and tenant selector

### Backend checklist

- [ ] Add protected `platform_admins` storage with active/revoked state.
- [ ] Add append-only, idempotent platform access events.
- [ ] Add platform authorization and read-only overview RPCs.
- [ ] Add paginated organization search and operational summaries.
- [ ] Keep existing organization RLS and write permissions unchanged.
- [ ] Generate and apply the migration locally.
- [ ] Regenerate backend and frontend database types.
- [ ] Pass focused database tests and full backend validation.

### Frontend checklist

- [ ] Add the `/platform` layout and access guard.
- [ ] Add automatic platform landing after login.
- [ ] Add the global overview and paginated organization table.
- [ ] Add the asynchronous tenant selector and selected-tenant summary.
- [ ] Prevent stale data from appearing while tenant scope changes.
- [ ] Skip ordinary tenant initialization and realtime work in platform mode.
- [ ] Record one idempotent access event per route entry.
- [ ] Pass focused frontend tests, build, lint, and full tests.

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

## Delivery log

| Date | Phase | Repository | Branch / commit | Migration | Validation | Environment | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-10 | 1 | Backend | `super-admin-foundation-backend` / pending | pending | pending | Local | Tracking started. |
| 2026-08-10 | 1 | Frontend | `super-admin-foundation-ui` / pending | n/a | pending | Local | Work begins after backend contract and generated types pass. |

## Deferred

- Editing tenant data from platform mode.
- Impersonating tenant users.
- Super Admin invitation or management UI.
- Report generation and export.
- Billing, quota, integration, assignment, or organization mutations.
- Read-only reuse of full tenant modules beyond the Phase 1 summary.

## Update rules

- Update status when a phase starts, reaches staging, or is completed.
- Record branches, commits, migration names, validation commands, staging
  results, and caveats in the delivery log.
- Mark a phase complete only after its acceptance scenario passes on staging.
- Record newly approved behavior before implementation so later phases do not
  rely on undocumented assumptions.
