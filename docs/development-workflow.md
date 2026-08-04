# Development workflow

Install the pinned local tooling once per worktree:

```powershell
npm ci
```

Use the repository commands instead of invoking an unpinned Supabase CLI:

```powershell
npm run db:diff -- <migration_name>
npm run db:migrate:local
npm run db:test -- supabase/tests/<test_file>.sql
```

Generate database types only after local migrations are applied. The generator
always requests `billing`, `public`, and `storage`, validates the output before
replacing the existing file, and can update an explicit frontend worktree in the
same operation:

```powershell
npm run types:generate
npm run types:generate -- --ui-file="../open-bsp-ui-feature/src/supabase/db_types.ts"
npm run types:generate -- --check
```

For enum additions, edit the schema first and generate the ordinary migration.
If the diff rebuilds an enum that existing functions depend on, replace that
section with a separate earlier append-only migration:

```sql
alter type public.<enum_name>
add value if not exists '<new_value>' before '<existing_value>';
```

The enum addition must commit before later migration statements use the new
value. Never modify an already-applied migration.

During implementation, use the quick validation loop:

```powershell
npm run validate:quick
```

Before commit, run the full validation once:

```powershell
npm run validate
```

Quick validation formats only changed files and checks all Edge Functions. Full
validation additionally checks the plugin and runs all local database tests. Use
`npm run validate -- --test <file>` for one database test, or
`npm run validate -- --skip-db` when a local database is intentionally
unavailable.
