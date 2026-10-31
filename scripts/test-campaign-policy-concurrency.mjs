// Local-only integration check. No HTTP or Meta calls; exact disposable fixture IDs.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";

const container = "supabase_db_open-bsp-api";
const org = "14000000-0000-4000-8000-000000000001";
function sql(input) {
  const r = spawnSync("docker", [
    "exec",
    "-i",
    container,
    "psql",
    "-U",
    "postgres",
    "-d",
    "postgres",
    "-XAt",
    "-v",
    "ON_ERROR_STOP=1",
  ], { input, encoding: "utf8", maxBuffer: 2_000_000 });
  if (r.status !== 0) throw new Error(r.stderr);
  return r.stdout.trim();
}
function concurrent(input) {
  return new Promise((resolve, reject) => {
    const p = spawn("docker", [
      "exec",
      "-i",
      container,
      "psql",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-XAt",
      "-v",
      "ON_ERROR_STOP=1",
    ]);
    let out = "", err = "";
    p.stdout.on("data", (c) => out += c);
    p.stderr.on("data", (c) => err += c);
    p.on("error", reject);
    p.on("close", (code) => code === 0 ? resolve(out) : reject(new Error(err)));
    p.stdin.end(input);
  });
}
assert.equal(
  sql(
    `select count(*) from public.organizations where id in ('${org}','14000000-0000-4000-8000-000000000002')`,
  ),
  "0",
  "Disposable fixture already exists; refusing to overwrite",
);
try {
  // Same tested setup as pgTAP, committed only for separate connection visibility.
  const fixture = readFileSync(
    "supabase/tests/campaign_sending_policy.sql",
    "utf8",
  );
  const setup = fixture.slice(
    0,
    fixture.indexOf(
      "select set_config('request.jwt.claims'",
      fixture.indexOf("from public.campaigns where organization_id="),
    ),
  );
  sql(
    setup + `
    select set_config('request.jwt.claims','{"sub":"14010000-0000-4000-8000-000000000001","role":"authenticated"}',true);
    select public.start_campaign('${org}','14030000-0000-4000-8000-000000000010');
    select public.start_campaign('${org}','14030000-0000-4000-8000-000000000011');
    update public.campaign_sending_policies set daily_limit=1,recipient_cap=5 where organization_id='${org}';
    select public.claim_campaign_dispatch_job(id) from public.campaign_dispatch_jobs where organization_id='${org}';
    commit;`,
  );
  const jobs = JSON.parse(
    sql(
      `select json_agg(json_build_object('id',id,'token',lease_token)) from public.campaign_dispatch_jobs where organization_id='${org}'`,
    ),
  );
  assert.equal(jobs.length, 2);
  const results = await Promise.all(
    jobs.map((j) =>
      concurrent(
        `begin; select public.lock_campaign_sending_policy('${org}'); select pg_sleep(0.4); select 'SEND='||public.begin_campaign_dispatch_send('${j.id}','${j.token}'); commit;`,
      )
    ),
  );
  assert.equal(
    results.filter((s) => s.includes("SEND=true")).length,
    1,
    "Exactly one transaction may reserve the last daily slot",
  );
  assert.equal(results.filter((s) => s.includes("SEND=false")).length, 1);
  assert.equal(
    sql(
      `select count(*) from public.campaign_send_ledger where organization_id='${org}' and state='reserved'`,
    ),
    "1",
  );
  assert.equal(
    sql(
      `select sum(attempts) from public.campaign_deliveries where organization_id='${org}'`,
    ),
    "1",
  );
  console.log(
    "PASS: two real concurrent DB connections cannot overspend the last daily slot; one attempt, zero external sends.",
  );
} finally {
  sql(
    `begin; set local app.organization_purge='on'; delete from public.organizations where id in ('${org}','14000000-0000-4000-8000-000000000002'); delete from auth.users where id in ('14010000-0000-4000-8000-000000000001','14010000-0000-4000-8000-000000000002'); commit;`,
  );
}
