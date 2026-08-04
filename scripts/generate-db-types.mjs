import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const requiredSchemas = ["billing", "public", "storage"];
const defaultDatabaseUrl =
  "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

const argumentsList = process.argv.slice(2);

function optionValue(name) {
  const exactIndex = argumentsList.indexOf(name);
  if (exactIndex >= 0) return argumentsList[exactIndex + 1] || "";

  const prefix = `${name}=`;
  const inlineOption = argumentsList.find((argument) =>
    argument.startsWith(prefix)
  );
  if (inlineOption) return inlineOption.slice(prefix.length);

  const environmentName = `npm_config_${name.slice(2).replaceAll("-", "_")}`;
  return process.env[environmentName] ?? null;
}

const checkOnly = argumentsList.includes("--check") ||
  process.env.npm_config_check === "true";
const outputValue = optionValue("--output-file");
const generatedTypesFile = resolve(
  repositoryRoot,
  outputValue !== null ? outputValue : "supabase/functions/_shared/db_types.ts",
);
const uiFileValue = optionValue("--ui-file");
const uiFile = uiFileValue !== null
  ? resolve(repositoryRoot, uiFileValue)
  : null;

if (uiFileValue !== null && !uiFileValue) {
  throw new Error("--ui-file requires a path to the frontend db_types.ts file");
}
if (outputValue !== null && !outputValue) {
  throw new Error("--output-file requires a destination path");
}

const supabaseCli = resolve(
  repositoryRoot,
  "node_modules/supabase/dist/supabase.js",
);

if (!existsSync(supabaseCli)) {
  throw new Error("Supabase CLI is not installed. Run npm ci first.");
}

const commandArguments = [
  "gen",
  "types",
  "typescript",
  "--db-url",
  process.env.SUPABASE_DB_URL || defaultDatabaseUrl,
  ...requiredSchemas.flatMap((schema) => ["--schema", schema]),
];
const result = spawnSync(process.execPath, [supabaseCli, ...commandArguments], {
  cwd: repositoryRoot,
  encoding: "utf8",
  maxBuffer: 20 * 1024 * 1024,
});

if (result.stderr) process.stderr.write(result.stderr);
if (result.status !== 0) {
  throw new Error(
    `Supabase type generation failed with exit code ${result.status}`,
  );
}

const generated = result.stdout.replaceAll("\r\n", "\n");
if (!generated.includes("export type Database")) {
  throw new Error(
    "Generated output is incomplete; existing types were preserved.",
  );
}
for (const schema of requiredSchemas) {
  if (!new RegExp(`^  ${schema}: \\{`, "m").test(generated)) {
    throw new Error(
      `Generated output is missing the ${schema} schema; existing types were preserved.`,
    );
  }
}

const files = [generatedTypesFile, ...(uiFile ? [uiFile] : [])];
const changedFiles = files.filter(
  (file) => !existsSync(file) || readFileSync(file, "utf8") !== generated,
);

if (checkOnly) {
  if (changedFiles.length > 0) {
    throw new Error(
      `Generated database types are stale: ${changedFiles.join(", ")}`,
    );
  }
  console.log(`Database types are current for ${requiredSchemas.join(", ")}.`);
  process.exit(0);
}

for (const file of changedFiles) {
  const temporaryFile = `${file}.${process.pid}.tmp`;
  writeFileSync(temporaryFile, generated, "utf8");
  renameSync(temporaryFile, file);
  console.log(`Updated ${file}`);
}

if (changedFiles.length === 0) {
  console.log("Database types are already current.");
}
