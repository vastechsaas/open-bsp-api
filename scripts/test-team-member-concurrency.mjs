// Local-only PostgreSQL race tests; never connects to a linked Supabase project.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
const container = process.env.LOCAL_SUPABASE_DB_CONTAINER ||
  "supabase_db_open-bsp-api";
const org = "e2000000-0000-4000-8000-000000000001";
const admin = "e2100000-0000-4000-8000-000000000001";
const member = (n) => "e2200000-0000-4000-8000-" + String(n).padStart(12, "0");
const auth = (n) => "e2100000-0000-4000-8000-" + String(n).padStart(12, "0");
const conv = "e2500000-0000-4000-8000-000000000001";
function start(sql) {
  const child = spawn("docker", [
    "exec",
    "-i",
    container,
    "psql",
    "-X",
    "-qAt",
    "-v",
    "ON_ERROR_STOP=1",
    "-U",
    "postgres",
    "-d",
    "postgres",
  ], { stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  let lockedResolve;
  const locked = new Promise((resolve) => lockedResolve = resolve);
  child.stdout.on("data", (data) => {
    stdout += data;
    if (stdout.includes("RACE_LOCKED")) lockedResolve();
  });
  child.stderr.on("data", (data) => stderr += data);
  const done = new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
  child.stdin.end("set statement_timeout='10s';\n" + sql);
  return { locked, done };
}
async function run(sql) {
  const result = await start(sql).done;
  assert.equal(result.code, 0, result.stderr);
  return result.stdout.trim();
}
const user =
  `set local role authenticated;select set_config('request.jwt.claim.sub','${admin}',true);`;
const stamp = (id) =>
  `(select updated_at from public.list_platform_organization_members_page('${org}',1,50) where id='${id}')`;
const remove = (id) =>
  `select public.remove_platform_organization_member('${id}',${
    stamp(id)
  },gen_random_uuid());`;
async function race(first, second, expected) {
  const a = start(
    `begin;${user}${first}select 'RACE_LOCKED';select pg_sleep(1);commit;`,
  );
  await Promise.race([
    a.locked,
    a.done.then((result) => {
      throw new Error("First transaction failed before lock: " + result.stderr);
    }),
  ]);
  const b = start(`begin;${user}${second}commit;`);
  assert.equal((await a.done).code, 0, "first transaction commits");
  const result = await b.done;
  assert.notEqual(result.code, 0, "conflicting transaction is rejected");
  assert.match(result.stderr, expected);
}
try {
  await run(`begin;
 insert into public.organizations(id,name,extra) values('${org}','Disposable team concurrency fixture','{}');
 insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data) values
 ('${admin}','team-race-platform@example.test','{}','{}'),
 ('${auth(2)}','team-race-owner-a@example.test','{}','{}'),
 ('${auth(3)}','team-race-owner-b@example.test','{}','{}'),
 ('${auth(4)}','team-race-agent@example.test','{}','{}');
 insert into public.platform_admins(user_id,active) values('${admin}',true);
 insert into public.agents(id,organization_id,user_id,name,ai,extra) values
 ('${member(2)}','${org}','${auth(2)}','Owner A',false,'{"role":"owner"}'),
 ('${member(3)}','${org}','${auth(3)}','Owner B',false,'{"role":"owner"}'),
 ('${member(4)}','${org}','${auth(4)}','Agent',false,'{"role":"agent"}');
 insert into public.organizations_addresses(organization_id,address,service,status,extra) values('${org}','race-local','local','connected','{}');
 insert into public.conversations(id,organization_id,organization_address,service) values('${conv}','${org}','race-local','local');
 commit;`);
  await race(
    remove(member(2)),
    `select public.update_platform_organization_member('${
      member(3)
    }','Owner B','supervisor','{}',${stamp(member(3))},gen_random_uuid());`,
    /Cannot delete the last owner/,
  );
  assert.equal(
    await run(
      `select count(*) from public.agents where organization_id='${org}' and extra->>'role'='owner';`,
    ),
    "1",
  );
  console.log(
    "PASS: concurrent owner removal/demotion preserves one accepted Owner",
  );
  // Assignment RPC is unnecessary: the shared trigger must fence every writer,
  // including background assignment. Postgres role here simulates that worker.
  const assign = start(
    `begin;update public.conversations set assigned_agent_id='${
      member(4)
    }' where id='${conv}';select 'RACE_LOCKED';select pg_sleep(1);commit;`,
  );
  await assign.locked;
  const removal = start(`begin;${user}${remove(member(4))}commit;`);
  assert.equal((await assign.done).code, 0);
  assert.match((await removal.done).stderr, /TEAM_MEMBER_ACTIVE_WORK/);
  console.log("PASS: committed assignment prevents concurrent member removal");
  await run(
    `update public.conversations set assigned_agent_id=null where id='${conv}';`,
  );
  const removeFirst = start(
    `begin;${user}${
      remove(member(4))
    }select 'RACE_LOCKED';select pg_sleep(1);commit;`,
  );
  await removeFirst.locked;
  const lateAssignment = start(
    `update public.conversations set assigned_agent_id='${
      member(4)
    }' where id='${conv}';`,
  );
  assert.equal((await removeFirst.done).code, 0);
  assert.match((await lateAssignment.done).stderr, /TEAM_MEMBER_UNAVAILABLE/);
  assert.equal(
    await run(
      `select assigned_agent_id is null from public.conversations where id='${conv}';`,
    ),
    "t",
  );
  console.log("PASS: removal prevents a late assignment to the removed member");
} finally {
  // Exact fixture IDs only; histories in other organizations are never touched.
  await run(`begin;set local app.organization_purge='on';
 delete from public.platform_admin_action_events where organization_id='${org}' and platform_admin_user_id='${admin}';
 delete from public.organizations where id='${org}';
 delete from public.platform_admins where user_id='${admin}';
 delete from auth.users where id in ('${admin}','${auth(2)}','${auth(3)}','${
    auth(4)
  }');commit;`);
}
