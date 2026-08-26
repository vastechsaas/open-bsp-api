import assert from "node:assert/strict";
import test from "node:test";
import { createRawEventStore } from "../src/raw-event-store.js";

test("stores the exact queue payload through Supabase before processing", async () => {
  const rawPayload = '{ "unchanged": true, "spacing":  "preserved" }\n';
  let request: { url: string; init?: RequestInit } | undefined;
  const store = createRawEventStore({
    supabaseUrl: "https://example.supabase.co",
    serviceRoleKey: "service-role-secret",
    queueName: "openbsp.chatbot.events.v1",
    fetchImpl: ((input: URL | RequestInfo, init?: RequestInit) => {
      request = { url: String(input), init };
      return Promise.resolve(new Response(null, { status: 201 }));
    }) as typeof fetch,
  });

  await store(rawPayload);

  assert.match(request!.url, /chatbot_integration_raw_events/);
  assert.equal(
    new Headers(request!.init?.headers).get("authorization"),
    "Bearer service-role-secret",
  );
  const inserted = JSON.parse(String(request!.init?.body)) as Record<
    string,
    unknown
  >;
  assert.equal(inserted.raw_payload, rawPayload);
  assert.equal(inserted.queue_name, "openbsp.chatbot.events.v1");
  assert.equal(typeof inserted.payload_sha256, "string");
  assert.match(inserted.payload_sha256 as string, /^[a-f0-9]{64}$/);
});

test("fails processing when Supabase does not accept the raw event", async () => {
  const store = createRawEventStore({
    supabaseUrl: "https://example.supabase.co",
    serviceRoleKey: "service-role-secret",
    queueName: "openbsp.chatbot.events.v1",
    fetchImpl: (() => Promise.resolve(new Response(null, { status: 500 }))) as typeof fetch,
  });

  await assert.rejects(() => store("{}"), /insert failed with 500/);
});
