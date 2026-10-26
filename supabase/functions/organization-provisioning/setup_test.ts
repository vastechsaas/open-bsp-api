import { assertEquals } from "../_shared/test_assert.ts";
import {
  processPerson,
  setupPayloadSchema,
  type SetupPerson,
} from "./setup.ts";
import type {
  Dependencies,
  Operation,
} from "../platform-user-onboarding/core.ts";
const id = "13000000-0000-4000-8000-000000000001";
const base: SetupPerson = {
  member_id: id,
  client_key: "owner",
  name: "Owner",
  email: "owner@example.test",
  role: "owner",
  mode: "direct",
  request_id: id,
  expected_updated_at: "2026-10-26T00:00:00Z",
  operation_id: null,
  status: "queued",
  failure_code: null,
  invitation_sent_at: null,
};
function fixture(mode: "direct" | "invitation" = "direct") {
  const commands: { name: string; input: Record<string, unknown> }[] = [];
  let accounts = 0, emails = 0;
  let op: Operation = {
    id,
    organization_id: id,
    member_id: id,
    intended_user_id: id,
    name: "Owner",
    email: base.email,
    role: "owner",
    mode,
    status: "reserved",
    generation: 0,
    failure_code: null,
    delivery_accepted_at: null,
    delivery_request_id: null,
    account_exists: false,
  };
  const deps: Dependencies = {
    secret: "test-only",
    callback: "https://staging.test/setup",
    command(name, input) {
      commands.push({ name, input });
      if (name === "finish") op.status = "completed";
      if (name === "sent") op.delivery_accepted_at = "sent";
      return Promise.resolve({ ...op });
    },
    createAccount() {
      accounts++;
      op.account_exists = true;
      return Promise.resolve();
    },
    send() {
      emails++;
      return Promise.resolve();
    },
    setInitialPassword() {
      throw new Error("Must not reset passwords");
    },
  };
  return {
    deps,
    commands,
    counts: () => ({ accounts, emails }),
    set: (patch: Partial<Operation>) => {
      op = { ...op, ...patch };
    },
  };
}
Deno.test("v2 create stores modes but rejects passwords, unknown fields and unsupported roles", () => {
  const payload = {
    version: 2,
    action: "create",
    request_id: id,
    organization_name: "Test",
    owner: { name: "Owner", email: base.email },
    members: [],
  };
  const parsed = setupPayloadSchema.parse(payload);
  assertEquals(parsed.action === "create" && parsed.owner.mode, "invitation");
  assertEquals(
    setupPayloadSchema.safeParse({
      ...payload,
      owner: { ...payload.owner, password: "never-store" },
    }).success,
    false,
  );
  assertEquals(
    setupPayloadSchema.safeParse({ ...payload, password: "never-store" })
      .success,
    false,
  );
  assertEquals(
    setupPayloadSchema.safeParse({
      ...payload,
      members: [{ ...payload.owner, client_key: "other", role: "admin" }],
    }).success,
    false,
  );
});
Deno.test("pending-only and completed/sent people perform no account or email work", async () => {
  for (
    const person of [
      { ...base, mode: "pending" as const, status: "pending_membership" },
      { ...base, status: "completed" },
      { ...base, mode: "invitation" as const, status: "invitation_sent" },
    ]
  ) {
    const f = fixture();
    await processPerson(person, id, {}, f.deps);
    assertEquals(f.commands.length, 0);
    assertEquals(f.counts(), { accounts: 0, emails: 0 });
  }
});
Deno.test("direct and invitation use the same executor against the reserved membership without persisting secrets", async () => {
  for (const mode of ["direct", "invitation"] as const) {
    const f = fixture(mode);
    await processPerson(
      { ...base, mode },
      id,
      mode === "direct" ? { password: "NotStored!123", confirmed: true } : {},
      f.deps,
    );
    assertEquals(f.commands[0].name, "begin");
    assertEquals(f.commands[0].input.member_id, id);
    assertEquals(f.commands[0].input.request_id, id);
    assertEquals(JSON.stringify(f.commands).includes("NotStored!123"), false);
    assertEquals(f.counts(), {
      accounts: 1,
      emails: mode === "invitation" ? 1 : 0,
    });
  }
});
Deno.test("ambiguous successful account creation is reconciled without recreating or resetting the account", async () => {
  const f = fixture();
  f.set({
    account_exists: true,
    has_password: true,
    status: "account_created",
  });
  await processPerson(
    { ...base, operation_id: id, status: "failed" },
    id,
    {},
    f.deps,
  );
  assertEquals(f.commands[0].name, "status");
  assertEquals(f.counts(), { accounts: 0, emails: 0 });
});
