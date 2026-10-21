// Local-only integration smoke. Retains synthetic Auth accounts; sends no email.
// deno run --config supabase/functions/deno.json --allow-run=node,docker
//   --allow-net=127.0.0.1 --allow-read scripts/verify-account-onboarding-local.ts
import {
  contextToken,
  type Dependencies,
  execute,
  type Operation,
} from "../supabase/functions/platform-user-onboarding/core.ts";

const cli = new URL(
  "../node_modules/supabase/dist/supabase.js",
  import.meta.url,
);
const result = await new Deno.Command("node", {
  args: [
    decodeURIComponent(cli.pathname).replace(/^\/(\w:)/, "$1"),
    "status",
    "--output",
    "json",
  ],
  stdout: "piped",
  stderr: "piped",
}).output();
if (!result.success) throw new Error("Local Supabase status is unavailable");
const config = JSON.parse(new TextDecoder().decode(result.stdout)) as Record<
  string,
  string
>;
if (config.API_URL !== "http://127.0.0.1:54321" || !config.SERVICE_ROLE_KEY) {
  throw new Error("Only the known local API is allowed");
}
const root = config.API_URL;
const service = config.SERVICE_ROLE_KEY;
const headers = {
  apikey: service,
  Authorization: `Bearer ${service}`,
  "Content-Type": "application/json",
};
async function api(path: string, body: object, method = "POST") {
  console.log(`Local smoke: ${method} ${path.split("?")[0]}`);
  const response = await fetch(`${root}/${path}`, {
    method,
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(45000),
  });
  const value = await response.json();
  if (!response.ok) {
    throw new Error(
      `Local API failure: ${path.split("?")[0]} HTTP ${response.status}`,
    );
  }
  return value;
}
const admin = crypto.randomUUID();
const organization = crypto.randomUUID();
const prefix = `onboarding-${crypto.randomUUID()}`;
const password = `LocalOnly-${crypto.randomUUID()}!9aA`;
await api("auth/v1/admin/users", {
  id: admin,
  email: `${prefix}-admin@example.test`,
  password,
  email_confirm: true,
});
const sql =
  `insert into public.organizations(id,name) values('${organization}','Phase 2 local smoke'); insert into public.platform_admins(user_id) values('${admin}');`;
const seeded = await new Deno.Command("docker", {
  args: [
    "exec",
    "supabase_db_open-bsp-api",
    "psql",
    "-U",
    "postgres",
    "-d",
    "postgres",
    "-v",
    "ON_ERROR_STOP=1",
    "-c",
    sql,
  ],
  stdout: "null",
  stderr: "piped",
}).output();
if (!seeded.success) throw new Error("Local fixture setup failed");
let actor: string = admin;
let recipientContext: string | undefined;
let sentContext = "";
let sendCalls = 0;
const deps: Dependencies = {
  callback: "https://vistagalaxy.vastech.biz/onboard/set-password",
  secret: "local-fixture-secret-not-used-outside-this-script",
  command: async (command, payload) => {
    const recipient = actor !== admin;
    const name = recipient && ["status", "failed"].includes(command)
      ? `complete_${command}`
      : command;
    const { digest } = await import(
      "../supabase/functions/platform-user-onboarding/core.ts"
    );
    const value = await api("rest/v1/rpc/platform_onboarding_command", {
      p_actor: actor,
      p_command: name,
      p_payload: {
        ...payload,
        ...(recipientContext
          ? { context_hash: await digest(recipientContext) }
          : {}),
      },
    });
    return value as Operation;
  },
  createAccount: (op, chosenPassword) =>
    api("auth/v1/admin/users", {
      id: op.intended_user_id,
      email: op.email,
      ...(chosenPassword ? { password: chosenPassword } : {}),
      email_confirm: op.mode === "direct",
      app_metadata: { onboarding_operation_id: op.id },
    }).then(() => {}),
  send: (_op, redirect) => {
    sendCalls++;
    sentContext = new URL(redirect).searchParams.get("context")!;
    return Promise.resolve();
  },
  setInitialPassword: (op, chosenPassword) =>
    api(`auth/v1/admin/users/${op.intended_user_id}`, {
      password: chosenPassword,
      app_metadata: {
        onboarding_operation_id: op.id,
        onboarding_password_set: true,
      },
    }, "PUT").then(() => {}),
};
for (const role of ["owner", "supervisor", "agent"] as const) {
  const email = `${prefix}-${role}@example.test`;
  const input = {
    action: "create",
    request_id: crypto.randomUUID(),
    organization_id: organization,
    name: `Local ${role}`,
    email,
    role,
    mode: "direct",
    password,
    confirmed: true,
  } as const;
  const created = await execute(input, deps);
  if (created.status !== "completed" || sendCalls !== 0) {
    throw new Error("Direct creation did not complete without email");
  }
  const login = await api("auth/v1/token?grant_type=password", {
    email,
    password,
  }) as { user?: { id: string } };
  if (!login.user?.id) throw new Error("Direct login failed");
  await execute(
    { ...input, password: "NotUsedBecauseAlreadyCompleted!9aA" },
    deps,
  );
  await api("auth/v1/token?grant_type=password", { email, password });
}
const email = `${prefix}-invitation@example.test`;
const invited = await execute({
  action: "create",
  request_id: crypto.randomUUID(),
  organization_id: organization,
  name: "Local invited agent",
  email,
  role: "agent",
  mode: "invitation",
}, deps);
if (!("operation_id" in invited)) {
  throw new Error("Missing invitation operation identity");
}
const status = await deps.command("status", {
  operation_id: invited.operation_id,
  organization_id: organization,
});
if (status.has_password || !status.account_exists || !sentContext) {
  throw new Error(
    "Random Auth password was incorrectly treated as completed setup",
  );
}
if (sentContext !== await contextToken(status, deps.secret)) {
  throw new Error("Context derivation changed");
}
// Simulate the native email verification boundary, not actual email delivery.
await api(`auth/v1/admin/users/${status.intended_user_id}`, {
  email_confirm: true,
}, "PUT");
actor = status.intended_user_id;
recipientContext = sentContext;
const completed = await execute({
  action: "complete",
  operation_id: invited.operation_id,
  context: sentContext,
  password,
}, deps);
if (completed.status !== "completed") throw new Error("Recipient setup failed");
await api("auth/v1/token?grant_type=password", { email, password });
console.log(
  "PASS: local direct login for Owner/Supervisor/Agent, stable retry without reset, and invitation password/join integration. No email sent; synthetic local accounts retained.",
);
