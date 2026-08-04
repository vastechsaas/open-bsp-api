# Contributing

Thanks for your interest in contributing to OpenBSP API!

## Local Setup

Requires Node, Docker, and
[Deno](https://docs.deno.com/runtime/getting_started/installation/) (used by the
Edge Functions and the CI checks).

1. Clone the repo:
   ```bash
   git clone https://github.com/matiasbattocchia/open-bsp-api
   cd open-bsp-api
   ```

2. Install the pinned local tooling:
   ```bash
   npm ci
   ```

3. Start the local Supabase instance:
   ```bash
   npm exec -- supabase start
   ```

4. Serve Edge Functions locally:
   ```bash
   npm exec -- supabase functions serve
   ```

## Database Changes

- Edit schema files in `supabase/schemas/` (never create tables directly via
  SQL)
- Generate a migration: `npm run db:diff -- <migration_name>`
- Apply it locally: `npm run db:migrate:local`
- Regenerate types: `npm run types:generate`

## Code Checks

CI runs `.github/workflows/check.yml` on every push and pull request. Install
the pinned tooling with `npm ci`, use `npm run validate:quick` during
implementation, and run the complete checks once before pushing:

```bash
npm run validate
```

The validation command format-checks changed files, checks the Edge Functions
and plugin from their correct import-map directories, and runs database tests.
See `docs/development-workflow.md` for targeted options.

## Submitting Changes

1. Fork the repo and create a branch from `develop`
2. Make your changes
3. Run the [code checks](#code-checks) and ensure they pass
4. Open a pull request with a clear description

PRs are welcome for bug fixes, new tools, protocol support, and documentation.
