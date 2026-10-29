import { assertEquals } from "jsr:@std/assert@1";
import {
  createDispatchHandler,
  type DispatchDependencies,
  type DispatchJob,
} from "./handler.ts";

const job: DispatchJob = {
  id: "10000000-0000-4000-8000-000000000001",
  organization_id: "20000000-0000-4000-8000-000000000001",
  campaign_id: "30000000-0000-4000-8000-000000000001",
  delivery_id: "40000000-0000-4000-8000-000000000001",
  phase: "pending",
  external_id: null,
  error_code: null,
};
const envelope = {
  version: 1,
  job_id: job.id,
  organization_id: job.organization_id,
  campaign_id: job.campaign_id,
  delivery_id: job.delivery_id,
};
function fixture() {
  const outcomes: string[] = [];
  let sends = 0;
  const deps: DispatchDependencies<string> = {
    serviceKey: "test-service-key",
    repository: {
      status: () => Promise.resolve(job),
      claim: () => Promise.resolve({ phase: "claimed", lease_token: "lease" }),
      begin: () => Promise.resolve(true),
      finish: (_id, _token, outcome) => {
        outcomes.push(outcome);
        return Promise.resolve(outcome);
      },
    },
    prepare: () => Promise.resolve("prepared"),
    send: () => {
      sends++;
      return Promise.resolve({ messages: [{ id: "wamid.test" }] });
    },
    classify: () => ({
      retryable: true,
      definitive: false,
      code: "network_error",
    }),
  };
  return { deps, outcomes, sends: () => sends };
}
function request(
  body: unknown = envelope,
  key = "test-service-key",
  method = "POST",
) {
  return new Request(`https://example.test/campaign-dispatch/jobs/${job.id}`, {
    method,
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    ...(method === "POST" ? { body: JSON.stringify(body) } : {}),
  });
}
Deno.test("campaign dispatch requires service authentication", async () => {
  const f = fixture();
  assertEquals(
    (await createDispatchHandler(f.deps)(request(envelope, "tenant-key")))
      .status,
    401,
  );
  assertEquals(f.sends(), 0);
});
Deno.test("campaign dispatch rejects forged tenant identity and extra secrets", async () => {
  const f = fixture();
  const handler = createDispatchHandler(f.deps);
  assertEquals(
    (await handler(request({ ...envelope, organization_id: "other" }))).status,
    400,
  );
  assertEquals(
    (await handler(request({ ...envelope, access_token: "secret" }))).status,
    400,
  );
  assertEquals(f.sends(), 0);
});
Deno.test("campaign dispatch records accepted exactly once", async () => {
  const f = fixture();
  assertEquals((await createDispatchHandler(f.deps)(request())).status, 200);
  assertEquals(f.outcomes, ["accepted"]);
  assertEquals(f.sends(), 1);
});
Deno.test("campaign status lookup has no send side effects", async () => {
  const f = fixture();
  assertEquals(
    (await createDispatchHandler(f.deps)(request(undefined, undefined, "GET")))
      .status,
    200,
  );
  assertEquals(f.sends(), 0);
});
Deno.test("campaign pending/in-flight duplicate does not send again", async () => {
  const f = fixture();
  f.deps.repository.claim = () => Promise.resolve({ phase: "submitting" });
  await createDispatchHandler(f.deps)(request());
  assertEquals(f.sends(), 0);
});
Deno.test("campaign stale preparation cannot cross send boundary", async () => {
  const f = fixture();
  f.deps.repository.begin = () => Promise.resolve(false);
  await createDispatchHandler(f.deps)(request());
  assertEquals(f.sends(), 0);
  assertEquals(f.outcomes, []);
});
Deno.test("campaign preflight network error is safe to retry without a Meta send", async () => {
  const f = fixture();
  f.deps.prepare = () => Promise.reject(new TypeError("network"));
  await createDispatchHandler(f.deps)(request());
  assertEquals(f.sends(), 0);
  assertEquals(f.outcomes, ["retry"]);
});
Deno.test("campaign timeout after submission requires review rather than resend", async () => {
  const f = fixture();
  f.deps.send = () => Promise.reject(new TypeError("network"));
  await createDispatchHandler(f.deps)(request());
  assertEquals(f.outcomes, ["needs_review"]);
});
Deno.test("campaign definitive transient rejection can schedule retry", async () => {
  const f = fixture();
  f.deps.send = () => Promise.reject(new Error("rejected"));
  f.deps.classify = () => ({
    retryable: true,
    definitive: true,
    code: "meta_130429",
  });
  await createDispatchHandler(f.deps)(request());
  assertEquals(f.outcomes, ["retry"]);
});
Deno.test("campaign missing Meta message ID requires review", async () => {
  const f = fixture();
  f.deps.send = () => Promise.resolve({ messages: [] });
  await createDispatchHandler(f.deps)(request());
  assertEquals(f.outcomes, ["needs_review"]);
});
Deno.test("campaign accepted write failure retries persistence only", async () => {
  const f = fixture();
  let writes = 0;
  f.deps.repository.finish = () => {
    writes++;
    if (writes === 1) return Promise.reject(new Error("DB unavailable"));
    return Promise.resolve("accepted");
  };
  await createDispatchHandler(f.deps)(request());
  assertEquals(f.sends(), 1);
  assertEquals(writes, 2);
});
