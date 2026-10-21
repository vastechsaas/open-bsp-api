import {
  contextToken,
  type Dependencies,
  digest,
  execute,
  type Operation,
  payloadSchema,
  SafeFailure,
} from "./core.ts";
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
const id = "e2400000-0000-4000-8000-000000000001";
const create = {
  action: "create",
  organization_id: id,
  request_id: id,
  name: "Test",
  email: "test@example.test",
  role: "agent",
  mode: "direct",
  password: "NotPersisted!123",
  confirmed: true,
} as const;
function fixture(mode: Operation["mode"] = "direct") {
  let op: Operation = {
    id,
    organization_id: id,
    member_id: id,
    intended_user_id: id,
    name: "Test",
    email: "test@example.test",
    role: "agent",
    mode,
    status: "reserved",
    generation: 0,
    failure_code: null,
    delivery_accepted_at: null,
    delivery_request_id: null,
    account_exists: false,
    has_password: false,
    email_confirmed: false,
  };
  const calls: Array<{ name: string; body: Record<string, unknown> }> = [];
  let creates = 0, sends = 0, passwords = 0;
  const deps: Dependencies = {
    callback: "https://vistagalaxy.vastech.biz/onboard/set-password",
    secret: "fixture-only-not-a-real-key",
    command: (name, body) => {
      calls.push({ name, body });
      if (name === "finish" || name === "complete_finish") {
        op = { ...op, status: "completed" };
      }
      if (name === "sent") {
        op = {
          ...op,
          status: "invitation_sent",
          delivery_accepted_at: new Date().toISOString(),
        };
      }
      return Promise.resolve({ ...op });
    },
    createAccount: (_op, password) => {
      creates++;
      op.account_exists = true;
      op.has_password = !!password;
      return Promise.resolve();
    },
    setInitialPassword: () => {
      passwords++;
      op.has_password = true;
      return Promise.resolve();
    },
    send: () => {
      sends++;
      return Promise.resolve();
    },
  };
  return {
    deps,
    calls,
    counts: () => ({ creates, sends, passwords }),
    set: (value: Partial<Operation>) => {
      op = { ...op, ...value };
    },
  };
}
Deno.test("direct creation creates and finalizes once, no email or password persisted in RPC payloads", async () => {
  const f = fixture();
  const result = await execute(create, f.deps);
  assert(result.status === "completed");
  assert(f.counts().creates === 1 && f.counts().sends === 0);
  assert(!JSON.stringify(f.calls).includes(create.password));
  await execute(create, f.deps);
  assert(f.counts().creates === 1);
});
Deno.test("invitation uses native delivery and durable context, no password", async () => {
  const f = fixture("invitation");
  const result = await execute({
    ...create,
    mode: "invitation",
    password: undefined,
  }, f.deps);
  assert(result.status === "invitation_sent" && f.counts().sends === 1);
  assert(f.calls.some((c) => c.name === "context"));
  await execute(
    { action: "retry", operation_id: id, organization_id: id },
    f.deps,
  );
  assert(f.counts().sends === 1);
});
Deno.test("ambiguous account creation retry reconciles without overwriting password", async () => {
  const f = fixture();
  f.set({ account_exists: true, has_password: true });
  await execute({
    action: "retry",
    operation_id: id,
    organization_id: id,
    password: "DifferentNotUsed",
  }, f.deps);
  assert(f.counts().creates === 0 && f.counts().passwords === 0);
});
Deno.test("direct retry without account needs password re-entry", async () => {
  const f = fixture();
  try {
    await execute(
      { action: "retry", operation_id: id, organization_id: id },
      f.deps,
    );
    throw new Error("expected failure");
  } catch (e) {
    assert(e instanceof SafeFailure && e.code === "PASSWORD_REENTRY_REQUIRED");
  }
  assert(f.counts().creates === 0);
});
Deno.test("recipient completion retries finalization without resetting an already set password", async () => {
  const f = fixture("invitation");
  f.set({ account_exists: true, has_password: true });
  await execute({
    action: "complete",
    operation_id: id,
    context: "c".repeat(64),
    password: "IgnoredOnRecovery",
  }, f.deps);
  assert(
    f.counts().passwords === 0 &&
      f.calls.some((c) => c.name === "complete_finish"),
  );
});
Deno.test("SMTP failures are safe and recoverable, not invitation sent", async () => {
  const f = fixture("invitation");
  f.deps.send = () => Promise.reject(new SafeFailure("SMTP_FAILED", 503));
  try {
    await execute(
      { ...create, mode: "invitation", password: undefined },
      f.deps,
    );
    throw new Error("expected failure");
  } catch (e) {
    assert(e instanceof SafeFailure && e.code === "SMTP_FAILED");
  }
  assert(
    f.calls.some((c) => c.name === "failed" && c.body.code === "SMTP_FAILED"),
  );
  assert(!f.calls.some((c) => c.name === "sent"));
});
Deno.test("context is stable for one attempt, changes on resend or secret rotation", async () => {
  const a = await contextToken({ id, generation: 0 }, "secret");
  assert(a === await contextToken({ id, generation: 0 }, "secret"));
  assert(a !== await contextToken({ id, generation: 1 }, "secret"));
  assert(a !== await contextToken({ id, generation: 0 }, "new-secret"));
  assert((await digest(a)).length === 64);
});
Deno.test("reject restricted roles, unknown body fields and mismatched direct confirmation", async () => {
  assert(!payloadSchema.safeParse({ ...create, role: "admin" }).success);
  assert(
    !payloadSchema.safeParse({ ...create, app_metadata: { admin: true } })
      .success,
  );
  const f = fixture();
  try {
    await execute({ ...create, confirmed: false }, f.deps);
    throw new Error("expected failure");
  } catch (e) {
    assert(
      e instanceof SafeFailure &&
        e.code === "ONBOARDING_DIRECT_CONFIRMATION_REQUIRED",
    );
  }
  assert(f.calls.length === 0);
});
