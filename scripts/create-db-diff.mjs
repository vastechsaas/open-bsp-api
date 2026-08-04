import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const migrationName = process.argv.slice(2).find((argument) =>
  !argument.startsWith("-")
);

if (!migrationName || !/^[a-z0-9_]+$/.test(migrationName)) {
  throw new Error(
    "Provide a lowercase migration name: npm run db:diff -- <migration_name>",
  );
}

const supabaseCli = resolve(
  repositoryRoot,
  "node_modules/supabase/dist/supabase.js",
);
if (!existsSync(supabaseCli)) {
  throw new Error("Supabase CLI is not installed. Run npm ci first.");
}

const isolatedSupabaseHome = resolve(
  repositoryRoot,
  "node_modules/.supabase-home",
);
mkdirSync(isolatedSupabaseHome, { recursive: true });

const result = spawnSync(process.execPath, [
  supabaseCli,
  "db",
  "diff",
  "--use-migra",
  "--file",
  migrationName,
], {
  cwd: repositoryRoot,
  env: { ...process.env, SUPABASE_HOME: isolatedSupabaseHome },
  stdio: "inherit",
  shell: false,
});
if (result.error) throw result.error;
if (result.status !== 0) {
  throw new Error(
    `Supabase schema diff failed with exit code ${result.status}`,
  );
}
