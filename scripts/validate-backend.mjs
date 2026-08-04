import { existsSync } from "node:fs";
import { dirname, extname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const argumentsList = process.argv.slice(2);
const quick = argumentsList.includes("--quick");

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

const skipDatabase = quick || argumentsList.includes("--skip-db") ||
  process.env.npm_config_skip_db === "true";
const baseOption = optionValue("--base");
const testOption = optionValue("--test");
const baseRef = baseOption ||
  process.env.VALIDATION_BASE_REF ||
  "origin/meta_vista_backend";
const databaseTest = testOption;
const startedAt = Date.now();

if (baseOption !== null && !baseOption) {
  throw new Error("--base requires a Git reference");
}
if (testOption !== null && !databaseTest) {
  throw new Error("--test requires a database test file");
}

function run(command, commandArguments, options = {}) {
  console.log(`\n> ${command} ${commandArguments.join(" ")}`);
  const result = spawnSync(command, commandArguments, {
    cwd: options.cwd || repositoryRoot,
    stdio: "inherit",
    shell: false,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} failed with exit code ${result.status}`);
  }
}

function captureGit(commandArguments) {
  const result = spawnSync("git", commandArguments, {
    cwd: repositoryRoot,
    encoding: "utf8",
    shell: false,
  });
  return result.status === 0 ? result.stdout.split(/\r?\n/) : [];
}

const changedFiles = new Set([
  ...captureGit([
    "diff",
    "--name-only",
    "--diff-filter=ACMR",
    `${baseRef}...HEAD`,
  ]),
  ...captureGit(["diff", "--name-only", "--diff-filter=ACMR"]),
  ...captureGit(["diff", "--cached", "--name-only", "--diff-filter=ACMR"]),
  ...captureGit(["ls-files", "--others", "--exclude-standard"]),
]);
const formattedExtensions = new Set([
  ".js",
  ".jsx",
  ".json",
  ".md",
  ".mjs",
  ".ts",
  ".tsx",
]);
const formatFiles = [...changedFiles]
  .map((file) => file.replaceAll("\\", "/"))
  .filter(Boolean)
  .filter((file) => file !== "supabase/functions/_shared/db_types.ts")
  .filter((file) => formattedExtensions.has(extname(file)))
  .filter((file) => existsSync(resolve(repositoryRoot, file)))
  .sort();

if (formatFiles.length > 0) {
  run("deno", ["fmt", "--check", ...formatFiles]);
} else {
  console.log("No changed files require a Deno format check.");
}

const functionsDirectory = resolve(repositoryRoot, "supabase/functions");
run("deno", ["lint"], { cwd: functionsDirectory });
run("deno", ["check", "."], { cwd: functionsDirectory });

if (!quick) {
  const pluginDirectory = resolve(repositoryRoot, "plugin");
  run("deno", ["lint"], { cwd: pluginDirectory });
  run("deno", ["check", "."], { cwd: pluginDirectory });
}

if (!skipDatabase) {
  const supabaseCli = resolve(
    repositoryRoot,
    "node_modules/supabase/dist/supabase.js",
  );
  if (!existsSync(supabaseCli)) {
    throw new Error("Supabase CLI is not installed. Run npm ci first.");
  }
  run(process.execPath, [
    supabaseCli,
    "test",
    "db",
    "--db-url",
    process.env.SUPABASE_DB_URL ||
    "postgresql://postgres:postgres@127.0.0.1:54322/postgres",
    ...(databaseTest ? [databaseTest] : []),
  ]);
}

console.log(
  `\n${quick ? "Quick" : "Full"} backend validation passed in ${
    Math.round(
      (Date.now() - startedAt) / 1000,
    )
  }s.`,
);
