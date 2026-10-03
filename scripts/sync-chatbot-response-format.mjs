// Portable formatter source is owned by OpenBSP. Explicit destinations allow
// feature worktrees without touching unrelated checkouts. --check never writes.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const args = process.argv.slice(2);
const source = resolve(
  import.meta.dirname,
  "../supabase/functions/_shared/chatbot/response_format.ts",
);
const destinations = ["ui-file", "node-file"].map((name) => {
  const value = args.find((arg) => arg.startsWith(`--${name}=`))?.slice(
    name.length + 3,
  );
  if (!value) throw new Error(`Provide --${name}=<formatter-file>`);
  return resolve(value);
});
function normalize(text) {
  const formatter = resolve(
    dirname(destinations[0]),
    "../../node_modules/prettier/bin/prettier.cjs",
  );
  const result = spawnSync(process.execPath, [
    formatter,
    "--parser",
    "typescript",
    "--no-config",
  ], {
    input: text,
    encoding: "utf8",
  });
  if (result.error || result.status !== 0) {
    throw result.error || new Error(result.stderr);
  }
  return result.stdout;
}
const text = readFileSync(source, "utf8");
for (const destination of destinations) {
  if (destination === source) {
    throw new Error("Destination must not be the canonical source");
  }
  if (args.includes("--check")) {
    if (normalize(readFileSync(destination, "utf8")) !== normalize(text)) {
      throw new Error(`Formatter mirror drift: ${destination}`);
    }
  } else writeFileSync(destination, text);
}
console.log(
  args.includes("--check")
    ? "Formatter mirrors match."
    : "Formatter mirrors synchronized; run the UI formatter on its copy.",
);
