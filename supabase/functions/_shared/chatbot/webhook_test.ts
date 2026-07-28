import { assertEquals } from "../test_assert.ts";
import { flowNodeV1Schema, type WebhookNodeV1 } from "./flow_definition.ts";
import {
  createWebhookExecutor,
  isPrivateOrLocalAddress,
  validateWebhookUrl,
} from "./webhook.ts";

function webhookNode(
  overrides: Partial<WebhookNodeV1["config"]> = {},
): WebhookNodeV1 {
  return {
    id: "webhook-1",
    type: "webhook",
    config: {
      method: "POST",
      url: "https://api.example.com/customers/{{customer_id}}",
      headers: [{ name: "X-Tenant", value: "{{tenant}}" }],
      body_template: '{"name":"{{name}}"}',
      timeout_ms: 2000,
      retry_count: 1,
      response_mappings: [
        { variable: "customer_status", path: "data.status" },
      ],
      ...overrides,
    },
  };
}

Deno.test("private, loopback, link-local, and metadata addresses are blocked", () => {
  for (
    const address of [
      "127.0.0.1",
      "10.0.0.1",
      "172.16.0.1",
      "192.168.1.1",
      "169.254.169.254",
      "::1",
      "fc00::1",
      "fe80::1",
    ]
  ) {
    assertEquals(isPrivateOrLocalAddress(address), true);
  }
  assertEquals(isPrivateOrLocalAddress("8.8.8.8"), false);
  assertEquals(isPrivateOrLocalAddress("2606:4700:4700::1111"), false);
});

Deno.test("URL validation rejects DNS names resolving to private addresses", async () => {
  let message = "";
  try {
    await validateWebhookUrl(
      "https://example.test/hook",
      () => Promise.resolve(["169.254.169.254"]),
    );
  } catch (error) {
    message = error instanceof Error ? error.message : String(error);
  }
  assertEquals(message.includes("metadata targets are blocked"), true);
});

Deno.test("webhook configuration rejects a templated origin", () => {
  const result = flowNodeV1Schema.safeParse(
    webhookNode({ url: "https://{{customer_host}}/customers" }),
  );

  assertEquals(result.success, false);
});

Deno.test("executor renders templates, applies protected headers, and maps scalar response values", async () => {
  let requestHeaders = new Headers();
  let requestBody = "";
  const executor = createWebhookExecutor({
    idempotencyKey: "run-message-lock",
    resolveDns: () => Promise.resolve(["8.8.8.8"]),
    resolveSecret: () => Promise.resolve({ Authorization: "Bearer protected" }),
    fetchImpl: ((_input, init) => {
      requestHeaders = new Headers(init?.headers);
      requestBody = String(init?.body);
      return Promise.resolve(
        new Response('{"data":{"status":"active"}}', { status: 200 }),
      );
    }) as typeof fetch,
  });

  const result = await executor(
    webhookNode({
      secret_id: "11111111-1111-4111-8111-111111111111",
    }),
    {
      customer_id: "42",
      tenant: "north",
      name: "Ada",
    },
  );

  assertEquals(result, {
    ok: true,
    status_code: 200,
    variable_updates: { customer_status: "active" },
  });
  assertEquals(requestHeaders.get("authorization"), "Bearer protected");
  assertEquals(requestHeaders.get("x-tenant"), "north");
  assertEquals(requestHeaders.get("idempotency-key"), "run-message-lock");
  assertEquals(requestBody, '{"name":"Ada"}');
});

Deno.test("executor retries only within the configured bound", async () => {
  let calls = 0;
  const executor = createWebhookExecutor({
    idempotencyKey: "bounded",
    resolveDns: () => Promise.resolve(["8.8.8.8"]),
    resolveSecret: () => Promise.resolve(null),
    fetchImpl: (() => {
      calls += 1;
      return Promise.resolve(new Response("temporary", { status: 503 }));
    }) as typeof fetch,
  });

  const result = await executor(
    webhookNode({
      secret_id: undefined,
      retry_count: 2,
      response_mappings: [],
    }),
    { customer_id: "42", tenant: "north", name: "Ada" },
  );

  assertEquals(calls, 3);
  assertEquals(result, {
    ok: false,
    status_code: 503,
    error_code: "webhook_http_error",
  });
});

Deno.test("redirect destinations are revalidated before following", async () => {
  let calls = 0;
  const executor = createWebhookExecutor({
    idempotencyKey: "redirect",
    resolveDns: (hostname) =>
      Promise.resolve(
        hostname === "metadata.example" ? ["169.254.169.254"] : ["8.8.8.8"],
      ),
    resolveSecret: () => Promise.resolve(null),
    fetchImpl: (() => {
      calls += 1;
      return Promise.resolve(
        new Response(null, {
          status: 302,
          headers: { location: "https://metadata.example/latest" },
        }),
      );
    }) as typeof fetch,
  });

  const result = await executor(
    webhookNode({ secret_id: undefined, retry_count: 0 }),
    { customer_id: "42", tenant: "north", name: "Ada" },
  );

  assertEquals(calls, 1);
  assertEquals(result, {
    ok: false,
    error_code: "webhook_request_failed",
  });
});
