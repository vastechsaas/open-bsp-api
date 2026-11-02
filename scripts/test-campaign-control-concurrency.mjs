// Local-only, two real database sessions. No HTTP requests or Meta sends.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";

const args = [
  "exec",
  "-i",
  "supabase_db_open-bsp-api",
  "psql",
  "-U",
  "postgres",
  "-d",
  "postgres",
  "-XAt",
  "-v",
  "ON_ERROR_STOP=1",
];
const org = "15000000-0000-4000-8000-000000000001";
const campaign = "15030000-0000-4000-8000-000000000001";
const actor =
  `select set_config('request.jwt.claims','{"sub":"15010000-0000-4000-8000-000000000001","role":"authenticated"}',true);`;
function sql(input) {
  const result = spawnSync("docker", args, {
    input,
    encoding: "utf8",
    maxBuffer: 2_000_000,
  });
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stdout.trim();
}
function session(input) {
  let mark;
  const marked = new Promise((resolve) => mark = resolve);
  const finished = new Promise((resolve, reject) => {
    const child = spawn("docker", args);
    let out = "", err = "";
    child.stdout.on("data", (chunk) => {
      out += chunk;
      if (out.includes("LOCKED_MARK")) mark();
    });
    child.stderr.on("data", (chunk) => err += chunk);
    child.on("error", reject);
    child.on("close", (code) => {
      mark();
      code === 0 ? resolve(out) : reject(new Error(err));
    });
    child.stdin.end(input);
  });
  return { marked, finished };
}
assert.equal(
  sql(
    `select count(*) from public.organizations where id in ('${org}','15000000-0000-4000-8000-000000000002')`,
  ),
  "0",
  "Fixture exists; refusing to overwrite",
);
let created = false;
try {
  const fixture = readFileSync("supabase/tests/campaign_controls.sql", "utf8");
  sql(
    fixture.slice(0, fixture.indexOf("select set_config")) + actor +
      `select public.start_campaign('${org}','${campaign}'); commit;`,
  );
  created = true;
  const job = JSON.parse(
    sql(
      `select row_to_json(j) from public.campaign_dispatch_jobs j where campaign_id='${campaign}' order by id limit 1`,
    ),
  );
  let token =
    JSON.parse(sql(`select public.claim_campaign_dispatch_job('${job.id}')`))
      .lease_token;
  const pause = session(
    `begin; ${actor} select public.pause_campaign('${org}','${campaign}',0,gen_random_uuid()); select 'LOCKED_MARK'; select pg_sleep(0.4); commit;`,
  );
  await pause.marked;
  const send = session(
    `select public.begin_campaign_dispatch_send('${job.id}','${token}');`,
  );
  await pause.finished;
  assert.equal(
    (await send.finished).trim(),
    "f",
    "Pause that commits first fences prepared send",
  );
  sql(
    `begin; ${actor} select public.resume_campaign('${org}','${campaign}',1,gen_random_uuid()); commit;`,
  );
  token =
    JSON.parse(sql(`select public.claim_campaign_dispatch_job('${job.id}')`))
      .lease_token;
  const authorized = session(
    `begin; select public.begin_campaign_dispatch_send('${job.id}','${token}'); select 'LOCKED_MARK'; select pg_sleep(0.4); commit;`,
  );
  await authorized.marked;
  const laterPause = session(
    `begin; ${actor} select public.pause_campaign('${org}','${campaign}',2,gen_random_uuid()); commit;`,
  );
  assert.match(await authorized.finished, /\bt\b/);
  await laterPause.finished;
  assert.equal(
    sql(
      `select public.finish_campaign_dispatch_job('${job.id}','${token}','accepted','wamid.mock.concurrent')`,
    ),
    "accepted",
    "Send authorized first can persist its outcome after pause",
  );
  const state = JSON.parse(
    sql(
      `select json_build_object('paused',paused_at is not null,'accepted',accepted_count,'attempts',(select sum(attempts) from public.campaign_deliveries where campaign_id='${campaign}')) from public.campaigns where id='${campaign}'`,
    ),
  );
  assert.deepEqual(state, { paused: true, accepted: 1, attempts: 1 });
  console.log(
    "PASS: both real pause/send lock orderings; one authorized mock acceptance, zero external sends.",
  );
} finally {
  if (created) {
    sql(
      `begin; set local app.organization_purge='on'; delete from public.organizations where id in ('${org}','15000000-0000-4000-8000-000000000002'); delete from auth.users where id in (select ('15010000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,5)n); commit;`,
    );
  }
}
