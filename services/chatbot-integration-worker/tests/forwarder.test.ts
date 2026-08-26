import assert from "node:assert/strict";
import test from "node:test";
import { createForwarder } from "../src/forwarder.js";
import { account, replyEvent, silentLogger, webhookEvent } from "./fixtures.js";

function makeForwarder(fetchImpl: typeof fetch, sleeps: number[] = []) {
  return createForwarder({
    functionsBaseUrl: "https://example.supabase.co/functions/v1",
    accounts: { psdf: account },
    logger: silentLogger,
    fetchImpl,
    sleep: (milliseconds) => {
      sleeps.push(milliseconds);
      return Promise.resolve();
    },
  });
}

test("forwards the exact raw webhook body, signature and configured app ID", async () => {
  let capturedUrl = "";
  let capturedInit: RequestInit | undefined;
  const result = await makeForwarder((url, init) => {
    capturedUrl = String(url);
    capturedInit = init;
    return Promise.resolve(new Response(null, { status: 200 }));
  })(webhookEvent);

  assert.equal(result.outcome, "success");
  assert.equal(
    capturedUrl.endsWith("/whatsapp-webhook?app_id=123456789012345"),
    true,
  );
  assert.equal(capturedInit?.body, webhookEvent.payload.raw_body);
  assert.equal(
    new Headers(capturedInit?.headers).get("X-Hub-Signature-256"),
    webhookEvent.payload.x_hub_signature_256,
  );
});

test("adds tenant credentials and chatbot identity only at forwarding time", async () => {
  let capturedInit: RequestInit | undefined;
  const result = await makeForwarder((_url, init) => {
    capturedInit = init;
    return Promise.resolve(new Response(null, { status: 201 }));
  })(replyEvent);

  assert.equal(result.outcome, "success");
  assert.equal(
    new Headers(capturedInit?.headers).get("Authorization"),
    "Bearer openbsp-secret",
  );
  const body = JSON.parse(String(capturedInit?.body)) as Record<
    string,
    unknown
  >;
  assert.deepEqual(body.chatbot, account.chatbot);
  assert.equal(body.wamid, "wamid.outgoing-1");
});

test("retries network, 429 and 5xx failures in the configured order", async () => {
  const sleeps: number[] = [];
  let attempt = 0;
  const result = await makeForwarder(() => {
    attempt += 1;
    if (attempt === 1) return Promise.reject(new TypeError("network"));
    if (attempt === 2) {
      return Promise.resolve(new Response(null, { status: 429 }));
    }
    return Promise.resolve(new Response(null, { status: 200 }));
  }, sleeps)(replyEvent);

  assert.deepEqual(sleeps, [1_000, 5_000]);
  assert.deepEqual(result, { outcome: "success", status: 200, attempts: 3 });
});

test("retries an exhausted 5xx response three times", async () => {
  const sleeps: number[] = [];
  let attempts = 0;
  const result = await makeForwarder(() => {
    attempts += 1;
    return Promise.resolve(new Response(null, { status: 503 }));
  }, sleeps)(replyEvent);

  assert.equal(attempts, 3);
  assert.deepEqual(sleeps, [1_000, 5_000]);
  assert.deepEqual(result, {
    outcome: "permanent_failure",
    status: 503,
    reason: "transient Edge Function failure exhausted retries",
    attempts: 3,
  });
});

test("retries request timeouts three times", async () => {
  const sleeps: number[] = [];
  let attempts = 0;
  const forward = createForwarder({
    functionsBaseUrl: "https://example.supabase.co/functions/v1",
    accounts: { psdf: account },
    logger: silentLogger,
    timeoutMs: 1,
    sleep: (milliseconds) => {
      sleeps.push(milliseconds);
      return Promise.resolve();
    },
    fetchImpl: () => {
      attempts += 1;
      return Promise.reject(new DOMException("timed out", "TimeoutError"));
    },
  });

  const result = await forward(replyEvent);
  assert.equal(attempts, 3);
  assert.deepEqual(sleeps, [1_000, 5_000]);
  assert.deepEqual(result, {
    outcome: "permanent_failure",
    reason: "network failure exhausted retries",
    attempts: 3,
  });
});

test("redelivery preserves the event ID and outgoing WAMID", async () => {
  const requests: Array<{ eventId: string | null; wamid: string }> = [];
  const forward = makeForwarder((_url, init) => {
    const body = JSON.parse(String(init?.body)) as { wamid: string };
    requests.push({
      eventId: new Headers(init?.headers).get("X-OpenBSP-Event-ID"),
      wamid: body.wamid,
    });
    return Promise.resolve(new Response(null, { status: 200 }));
  });

  await forward(replyEvent);
  await forward(replyEvent);
  assert.deepEqual(requests, [
    { eventId: replyEvent.event_id, wamid: "wamid.outgoing-1" },
    { eventId: replyEvent.event_id, wamid: "wamid.outgoing-1" },
  ]);
});

test("does not retry permanent 4xx failures", async () => {
  let attempts = 0;
  const result = await makeForwarder(() => {
    attempts += 1;
    return Promise.resolve(new Response(null, { status: 401 }));
  })(replyEvent);
  assert.equal(attempts, 1);
  assert.deepEqual(result, {
    outcome: "permanent_failure",
    status: 401,
    reason: "Edge Function returned HTTP 401",
    attempts: 1,
  });
});

test("rejects unknown and mismatched account configuration without HTTP", async () => {
  let called = false;
  const forward = makeForwarder(() => {
    called = true;
    return Promise.resolve(new Response());
  });
  const unknown = await forward({ ...replyEvent, integration_key: "missing" });
  const mismatch = await forward({
    ...replyEvent,
    payload: { ...replyEvent.payload, phone_number_id: "19999999999" },
  });
  assert.equal(unknown.outcome, "permanent_failure");
  assert.equal(mismatch.outcome, "permanent_failure");
  assert.equal(called, false);
});
