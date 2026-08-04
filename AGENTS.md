# Codex Instructions

## Project context

This is the OpenBSP backend: a Supabase/Postgres/Deno API for WhatsApp,
Instagram, messaging, agents, integrations, billing, and webhooks.

Read `README.md` before making backend changes. The related frontend lives at:

```text
C:\Hurera New Laptop\open-bsp-ui
```

## Branches and staging

- Backend staging branch: `meta_vista_backend`.
- Frontend staging branch: `meta_vista_frontend`.
- Do not merge feature work directly to `main` unless the user explicitly asks.
- For Jira feature slices, use plain ticket/feature branch names such as
  `scrum-13-assignment-tests-docs`; do not add the `codex/` prefix unless the
  user asks for it.
- Merge and validate backend changes before frontend changes that depend on new
  schema, RPCs, policies, or generated types.

## Database schema and migrations

- Schema files are the source of truth and live under `supabase/schemas/`.
- Edit schema files first. Do not create tables/functions/policies directly in a
  database console.
- Do not hand-write ordinary migrations. Generate them from schema diffs:

```powershell
npm run db:diff -- -f <migration_name>
```

- Apply locally before committing when possible:

```powershell
npm run db:migrate:local
```

- Do not modify already-applied migrations unless the user explicitly asks and
  understands the risk.
- Exceptions that may require hand-edited migration content include data
  backfills, enum append-only fixes, cron jobs, and trimming known spurious
  Supabase `revoke` noise emitted by `db diff`.

## Generated types

`supabase/functions/_shared/db_types.ts` is generated. Never edit it manually.

After local schema/migration changes are applied, regenerate:

```powershell
npm run types:generate
```

The UI mirrors this generated file at:

```text
../open-bsp-ui/src/supabase/db_types.ts
```

The generator requires the `billing`, `public`, and `storage` schemas.

## Paginated data-table APIs

Use backend pagination for list screens that can grow. Do not fetch every row
and paginate with frontend `slice()`.

- Create a module-specific RPC with the shared pagination contract:
  `p_organization_id`, `p_page`, `p_page_size`, optional `p_search`, and
  module-specific filters.
- Return the requested rows with `total_count` so the UI can calculate page
  controls without a second count request.
- Apply organization authorization, search, and filters before counting and
  pagination. Keep RLS active and use deterministic ordering with a unique
  tie-breaker such as `updated_at desc, id desc`.
- Cap `p_page_size` at a safe value. The frontend standard options are 10, 25,
  and 50 rows.
- Include list-only derived values in the same RPC when practical. Avoid N+1
  requests such as one count RPC for every visible row.
- Add database tests for organization isolation, totals, page size, search,
  filters, and derived list values.

`public.list_campaigns_page` is the reference implementation. Other modules
should use the same contract while keeping their SQL and filters
module-specific.

## Required checks

Use the quick loop while implementing, then run the full suite once before
commit:

```powershell
npm run validate:quick
npm run validate
```

The scripts format-check changed files and run `deno check .` from
`supabase/functions`, where its import map is available. Full validation also
checks the plugin and runs database tests.

For database tests:

```powershell
npm run db:test -- supabase/tests/<test_file>.sql
```

If local discovery is flaky but the DB container is healthy, use the explicit
local DB URL:

```powershell
npm run db:test -- supabase/tests/<test_file>.sql
```

Install the pinned repository tooling with `npm ci`. During development use
`npm run validate:quick`; run `npm run validate` once before committing. The
type generator always includes `billing`, `public`, and `storage`, validates its
output before replacement and supports `--ui-file=<path>` to sync an explicit
frontend worktree. See `docs/development-workflow.md`.

## Staging migration safety

For staging deployment, make sure the target Supabase project is the staging
project before applying migrations:

```powershell
npm exec -- supabase link --project-ref <STAGING_PROJECT_REF>
npm exec -- supabase db push --dry-run
npm exec -- supabase db push
```

Never run staging or production migration commands without confirming the linked
project/ref.

## Feature-slice workflow

For Jira-driven work:

1. Read the Jira ticket and keep scope to its acceptance criteria.
2. Branch from the latest relevant staging/feature branch.
3. Implement backend foundation first when schema/RPC/policy changes are needed.
4. Generate migrations and types through the documented workflow.
5. Sync UI types only after backend types are regenerated.
6. Validate backend, then validate frontend.
7. Push feature branches and update Jira with branch, commit, validation, and
   known caveats.

Keep reference projects as behavioral input only. Do not copy implementation
code from another codebase.
