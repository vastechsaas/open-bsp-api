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
npx supabase db diff -f <migration_name>
```

- Apply locally before committing when possible:

```powershell
npx supabase migration up --local
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
npx supabase gen types typescript --local > supabase/functions/_shared/db_types.ts
```

The UI mirrors this generated file at:

```text
../open-bsp-ui/src/supabase/db_types.ts
```

When syncing to UI, ensure the generated types include the `billing` schema.

## Required checks

Run Deno checks from the correct directories:

```powershell
deno fmt --check
cd supabase/functions
deno lint
deno check .
```

`deno check .` must be run from `supabase/functions`, because the import map is
there. Running `deno check <file>` from the repo root can produce false missing
dependency errors.

For database tests:

```powershell
npx supabase test db --local supabase/tests/<test_file>.sql
```

If local discovery is flaky but the DB container is healthy, use the explicit
local DB URL:

```powershell
npx supabase test db --db-url "postgresql://postgres:postgres@127.0.0.1:54322/postgres" supabase/tests/<test_file>.sql
```

## Staging migration safety

For staging deployment, make sure the target Supabase project is the staging
project before applying migrations:

```powershell
npx supabase link --project-ref <STAGING_PROJECT_REF>
npx supabase db push --dry-run
npx supabase db push
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
