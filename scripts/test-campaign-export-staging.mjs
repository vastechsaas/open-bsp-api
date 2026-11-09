// Explicit no-send staging smoke test. Creates synthetic fixtures only, then
// archives its isolated organization. Never uses a customer token/phone number.
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const ref = "acifbsuxmpdtlhbsvhlj";
assert.equal(readFileSync("supabase/.temp/project-ref", "utf8").trim(), ref);
assert.equal(process.argv.includes("--create-isolated-fixture"), true);
const cli = resolve("node_modules/supabase/dist/supabase.js");
const keyResponse = JSON.parse(
  execFileSync(process.execPath, [
    cli,
    "projects",
    "api-keys",
    `--project-ref=${ref}`,
    "--output=json",
  ], { encoding: "utf8" }),
);
const keys = Array.isArray(keyResponse)
  ? keyResponse
  : keyResponse.api_keys ?? keyResponse.keys;
const service = keys.find((key) => key.name === "service_role").api_key;
const anon = keys.find((key) => key.name === "anon").api_key;
const base = `https://${ref}.supabase.co`;
async function api(path, body, token = service, method = "POST", preference) {
  const response = await fetch(base + path, {
    method,
    headers: {
      apikey: anon,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(preference ? { Prefer: preference } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) {
    throw new Error(
      `Staging smoke ${path.split("?")[0]}: HTTP ${response.status}`,
    );
  }
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}
const rpc = (name, body, token) => api(`/rest/v1/rpc/${name}`, body, token);
const tag = randomUUID().slice(0, 8);
const org = randomUUID(), campaign = randomUUID(), agent = randomUUID();
const name = `CSV export isolated no-send ${tag}`;
const email = `csv-export-${tag}@example.test`;
let ownerToken;
let orgCreated = false;
let ownerCreated = false;
try {
  const password = `A!z9${randomBytes(24).toString("hex")}`;
  const user = await api("/auth/v1/admin/users", {
    email,
    password,
    email_confirm: true,
  });
  const session = await api("/auth/v1/token?grant_type=password", {
    email,
    password,
  }, anon);
  ownerToken = session.access_token;
  await api("/rest/v1/organizations", { id: org, name });
  orgCreated = true;
  await api("/rest/v1/agents", [
    {
      id: agent,
      organization_id: org,
      user_id: user.id,
      name: "Synthetic export Owner",
      ai: false,
      extra: { role: "owner" },
    },
    {
      id: randomUUID(),
      organization_id: org,
      user_id: null,
      name: "Synthetic second Owner",
      ai: false,
      extra: { role: "owner" },
    },
  ]);
  ownerCreated = true;
  const address = `csv-export-${tag}`;
  await api("/rest/v1/organizations_addresses", {
    organization_id: org,
    address,
    service: "whatsapp",
    status: "disconnected",
    extra: { phone_number: "+15550000000", verified_name: "Synthetic sender" },
  });
  await api("/rest/v1/campaigns", {
    id: campaign,
    organization_id: org,
    name: "Completed CSV fixture — no sends",
    organization_address: address,
    audience_type: "csv_upload",
    status: "completed",
    schedule_timezone: "Asia/Karachi",
    template: {
      id: "synthetic-not-submitted-to-meta",
      name: "csv_fixture",
      language: "en_US",
      status: "APPROVED",
      components: [{ type: "BODY", text: "Hello {{1}}" }],
    },
    template_variable_mapping: { "body.1": "contact.name" },
  });
  const rows = Array.from({ length: 601 }, (_, i) => ({
    id: randomUUID(),
    organization_id: org,
    campaign_id: campaign,
    contact_address: `+1555${String(i).padStart(7, "0")}`,
    name: `Synthetic ${i}`,
    status: i === 2 ? "failed" : "accepted",
    attempts: 0,
  }));
  await api("/rest/v1/campaign_deliveries", rows);
  await api("/rest/v1/campaign_delivery_receipts", [
    {
      delivery_id: rows[0].id,
      organization_id: org,
      campaign_id: campaign,
      read_at: new Date().toISOString(),
      failed_at: null,
    },
    {
      delivery_id: rows[1].id,
      organization_id: org,
      campaign_id: campaign,
      failed_at: new Date().toISOString(),
      read_at: null,
    },
  ]);
  const input = { p_organization_id: org, p_campaign_id: campaign };
  const requested = await rpc("request_campaign_log_export", {
    ...input,
    p_request_id: randomUUID(),
  }, ownerToken);
  assert.equal(requested.row_count, 601);
  assert.equal(
    (await rpc("get_campaign_log_export", input, ownerToken)).id,
    requested.id,
  );
  const anonymous = await fetch(`${base}/functions/v1/campaign-log-export`, {
    method: "POST",
  });
  assert.equal(anonymous.status, 401);
  let state;
  for (let n = 0; n < 8; n++) {
    await api("/functions/v1/campaign-log-export", {});
    state = await rpc("get_campaign_log_export", input, ownerToken);
    if (state.state === "ready") break;
    assert.notEqual(state.state, "failed");
  }
  assert.equal(state.state, "ready");
  assert.equal(state.processed_count, 601);
  const ticket = await rpc("issue_campaign_log_download", {
    p_export_id: state.id,
  }, ownerToken);
  // Exactly the browser form request: no Authorization/apikey headers or URL token.
  const download = await fetch(
    `${base}/functions/v1/campaign-log-export/download`,
    { method: "POST", body: new URLSearchParams({ ticket }) },
  );
  assert.equal(download.status, 200);
  assert.match(download.headers.get("content-disposition"), /^attachment;/);
  const csv = await download.text();
  const lines = csv.trimEnd().split("\r\n");
  assert.equal(lines.length, 602);
  assert.equal(lines.filter((line) => line.endsWith(',"Delivered"')).length, 1);
  assert.equal(
    lines.filter((line) => line.endsWith(',"Not Delivered"')).length,
    2,
  );
  assert.equal(lines.filter((line) => line.endsWith(',""')).length, 598);
  assert.ok(csv.includes("Hello Synthetic 600"));
  const replay = await fetch(
    `${base}/functions/v1/campaign-log-export/download`,
    { method: "POST", body: new URLSearchParams({ ticket }) },
  );
  assert.equal(replay.status, 403);
  const raw = await fetch(
    `${base}/rest/v1/campaign_log_export_rows?export_id=eq.${state.id}`,
    { headers: { apikey: anon, Authorization: `Bearer ${ownerToken}` } },
  );
  assert.equal(raw.status, 403);
  await api(
    `/rest/v1/agents?id=eq.${agent}`,
    { extra: { role: "admin" } },
    service,
    "PATCH",
  );
  const denied = await fetch(`${base}/rest/v1/rpc/get_campaign_log_export`, {
    method: "POST",
    headers: {
      apikey: anon,
      Authorization: `Bearer ${ownerToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(input),
  });
  assert.equal(denied.status, 403);
  await api(
    `/rest/v1/agents?id=eq.${agent}`,
    { extra: { role: "owner" } },
    service,
    "PATCH",
  );
  console.log(
    JSON.stringify({
      project: ref,
      organization_id: org,
      campaign_id: campaign,
      export_id: state.id,
      recipients: 601,
      delivered: 1,
      not_delivered: 2,
      unknown: 598,
      sends: 0,
      result: "passed",
    }),
  );
} finally {
  if (orgCreated && ownerCreated && ownerToken) {
    await api(
      `/rest/v1/agents?id=eq.${agent}`,
      { extra: { role: "owner" } },
      service,
      "PATCH",
    );
    await rpc("archive_organization", {
      p_organization_id: org,
      p_expected_name: name,
      p_reason: "Isolated CSV export no-send smoke test completed",
      p_request_id: randomUUID(),
    }, ownerToken);
    console.log(
      "Isolated fixture organization archived; no customer accounts changed.",
    );
  }
}
