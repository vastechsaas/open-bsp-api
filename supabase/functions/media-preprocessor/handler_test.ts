import { assertEquals } from "../_shared/test_assert.ts";
import { createMediaHandler, type MediaRepository } from "./handler.ts";
import type { MessageRow } from "../_shared/supabase.ts";

const messageId = "16000000-0000-4000-8000-000000000001";
const lease = "16000000-0000-4000-8000-000000000002";
const current = {
  id: messageId,
  content: { type: "file", kind: "image" },
} as MessageRow;
const request = (
  key = "internal",
  body: unknown = { message_id: messageId, lease_token: lease },
) =>
  new Request("https://test/media-preprocessor", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

Deno.test("preprocessing uses internal/service credentials and never processes an unauthorized body", async () => {
  let reservations = 0;
  let processed = 0;
  const repository: MediaRepository = {
    reserve: () => {
      reservations++;
      return Promise.resolve(null);
    },
    start: () => Promise.resolve(false),
    message: () => Promise.resolve(current),
    finish: () => Promise.resolve(true),
  };
  const handle = createMediaHandler({
    repository,
    edgeToken: "internal",
    serviceRoleKey: "service",
    process: () => {
      processed++;
      return Promise.resolve({ outcome: "skipped" });
    },
  });
  assertEquals((await handle(request("wrong"))).status, 401);
  assertEquals(
    (await handle(request("service", { message_id: "not-a-uuid" }))).status,
    400,
  );
  assertEquals(reservations, 0);
  assertEquals(
    (await handle(request("internal", { record: { id: messageId } }))).status,
    200,
  );
  assertEquals(
    (await handle(request("service", { record: { id: messageId } }))).status,
    200,
  );
  assertEquals(reservations, 2);
  assertEquals(processed, 0);
  const unconfigured = createMediaHandler({
    repository,
    process: () => Promise.resolve({ outcome: "skipped" }),
  });
  assertEquals((await unconfigured(request(""))).status, 401);
});

Deno.test("duplicate deliveries and disabled jobs do not run media analysis", async () => {
  let called = false;
  const handle = createMediaHandler({
    edgeToken: "internal",
    repository: {
      reserve: () => Promise.resolve(lease),
      start: () => Promise.resolve(false),
      message: () => {
        throw new Error("Must not load disabled/duplicate work");
      },
      finish: () => Promise.resolve(false),
    },
    process: () => {
      called = true;
      return Promise.resolve({ outcome: "succeeded" });
    },
  });
  assertEquals((await handle(request())).status, 200);
  assertEquals(called, false);
});

Deno.test("analysis uses current persisted content, not stale or forged webhook record fields", async () => {
  const outcomes: string[] = [];
  let observed: MessageRow | undefined;
  const handle = createMediaHandler({
    serviceRoleKey: "service",
    repository: {
      reserve: () => Promise.resolve(lease),
      start: () => Promise.resolve(true),
      message: () => Promise.resolve(current),
      finish: (_id, _token, result) => {
        outcomes.push(result.outcome);
        return Promise.resolve(true);
      },
    },
    process: (message) => {
      observed = message;
      return Promise.resolve({ outcome: "succeeded", artifacts: [] });
    },
  });
  assertEquals(
    (await handle(
      request("service", { record: { id: messageId, content: "forged" } }),
    )).status,
    200,
  );
  assertEquals(observed, current);
  assertEquals(outcomes, ["succeeded"]);
});

Deno.test("transient errors schedule a durable retry without logging provider payloads", async () => {
  const outcomes: string[] = [];
  const handle = createMediaHandler({
    edgeToken: "internal",
    repository: {
      reserve: () => Promise.resolve(lease),
      start: () => Promise.resolve(true),
      message: () => Promise.resolve(current),
      finish: (_id, _token, result) => {
        outcomes.push(result.outcome);
        return Promise.resolve(true);
      },
    },
    process: () => {
      throw new Error("private provider response");
    },
  });
  const result = await handle(request());
  assertEquals(result.status, 503);
  assertEquals((await result.text()).includes("private"), false);
  assertEquals(outcomes, ["retry"]);
});
