import { processNodeBridgeOperation } from "./node_bridge_processor.ts";
import { assertEquals } from "../test_assert.ts";

function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}

const organization = "12300000-0000-4000-8000-000000000001";
const requestId = "12340000-0000-4000-8000-000000000001";

async function scenario(
  remote: (
    path: string,
    method: string,
    body: Record<string, unknown>,
  ) => Response,
  attempts = 1,
  status = "reconciling",
  action = "resolve-and-close",
) {
  const originalFetch = globalThis.fetch;
  const settings = {
    SUPABASE_URL: "https://db.example.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "test-only-key",
    NODE_CHATBOT_BRIDGE_ENABLED: "true",
    NODE_CHATBOT_CONNECTIONS: JSON.stringify({
      [`${organization}:90000123`]: {
        url: "https://node.example.invalid",
        company_id: "123",
        credential: "test-credential-never-sent-outside-mock",
      },
    }),
  };
  const previous = Object.fromEntries(
    Object.keys(settings).map((key) => [key, Deno.env.get(key)]),
  );
  for (const [key, value] of Object.entries(settings)) Deno.env.set(key, value);
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  const operation = {
    request_id: requestId,
    organization_id: organization,
    organization_address: "90000123",
    conversation_id: "12330000-0000-4000-8000-000000000001",
    action,
    phase: action,
    attempts,
    status,
    next_attempt_at: null,
    payload: {
      node_conversation_id: "1",
      expected_revision: "1",
      observed_last_inbound_wamid: "wamid.old",
      actor_agent_id: "12320000-0000-4000-8000-000000000001",
    },
  };
  globalThis.fetch = (input, init) => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    const body = init?.body
      ? JSON.parse(String(init.body)) as Record<string, unknown>
      : {};
    if (url.hostname === "node.example.invalid") {
      return Promise.resolve(remote(url.pathname, method, body));
    }
    assertEquals(url.hostname, "db.example.invalid");
    if (method !== "GET") writes.push({ path: url.pathname, body });
    if (url.pathname.endsWith("/rpc/complete_node_chatbot_operation")) {
      return Promise.resolve(
        Response.json({ ...operation, status: "succeeded" }),
      );
    }
    if (method === "GET") return Promise.resolve(Response.json(operation));
    if (url.searchParams.has("select")) {
      return Promise.resolve(Response.json({ ...operation, ...body }));
    }
    return Promise.resolve(new Response(null, { status: 204 }));
  };
  try {
    return { result: await processNodeBridgeOperation(requestId), writes };
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      value === undefined ? Deno.env.delete(key) : Deno.env.set(key, value);
    }
  }
}

Deno.test("takeover forwards server-derived actor and reconciles the same request before enabling replies", async () => {
  const { result, writes } = await scenario(
    (_path, method, body) => {
      if (method === "PUT") {
        assertEquals(body.action, "takeover");
        assertEquals(
          body.actor_agent_id,
          "12320000-0000-4000-8000-000000000001",
        );
        assertEquals(body.client_request_id, requestId);
      }
      return Response.json({
        data: {
          revision: "2",
          state: "human_owned",
          last_inbound_wamid: "wamid.old",
        },
      });
    },
    0,
    "pending",
    "takeover",
  );
  assertEquals(result.status, "succeeded");
  assert(
    writes.some((write) =>
      write.path.endsWith("/rpc/complete_node_chatbot_operation")
    ),
  );
  assert(!writes.some((write) => write.path.endsWith("chatbot_node_bridges")));
});

Deno.test("conversation retry exhaustion releases only its pending state after confirmed absence", async () => {
  const { result, writes } = await scenario(
    () => new Response(null, { status: 404 }),
    5,
  );
  assertEquals(result.status, "failed");
  assert(
    writes.some((write) =>
      write.path.endsWith("chatbot_node_conversations") &&
      write.body.pending_request_id === null
    ),
  );
  assert(!writes.some((write) => write.path.endsWith("chatbot_node_bridges")));
});

Deno.test("Node outage keeps ambiguous closure pending without resubmitting or releasing human sending", async () => {
  const { writes } = await scenario((_path, method) => {
    assertEquals(method, "GET");
    return new Response(null, { status: 503 });
  }, 5);
  assert(writes.some((write) => write.body.status === "reconciling"));
  assert(
    !writes.some((write) => write.path.endsWith("chatbot_node_conversations")),
  );
});

Deno.test("old close ACK reconciles the current revision so it cannot overwrite a new handoff", async () => {
  const { result, writes } = await scenario((path) =>
    Response.json({
      data: path.includes("/operations/")
        ? { revision: "2", state: "closed" }
        : {
          revision: "4",
          state: "human_owned",
          last_inbound_wamid: "wamid.new",
        },
    })
  );
  assertEquals(result.status, "succeeded");
  const completion = writes.find((write) =>
    write.path.endsWith("/rpc/complete_node_chatbot_operation")
  );
  assertEquals(completion?.body.p_result, {
    revision: "4",
    state: "human_owned",
    last_inbound_wamid: "wamid.new",
  });
  assert(!writes.some((write) => write.path.endsWith("chatbot_node_bridges")));
});

Deno.test("new customer message rejection clears only that conversation and returns guidance", async () => {
  const { result, writes } = await scenario(
    (_path, method, body) => {
      assertEquals(method, "PUT");
      assertEquals(body.client_request_id, requestId);
      assertEquals(body.observed_last_inbound_wamid, "wamid.old");
      return Response.json({ message: "NEW_CUSTOMER_MESSAGE" }, {
        status: 409,
      });
    },
    0,
    "pending",
  );
  assertEquals(result.status, "failed");
  assertEquals(
    result.last_error,
    "A new customer message arrived—review it before closing.",
  );
  assert(
    writes.some((write) =>
      write.path.endsWith("chatbot_node_conversations") &&
      write.body.pending_request_id === null
    ),
  );
  assert(!writes.some((write) => write.path.endsWith("chatbot_node_bridges")));
});
