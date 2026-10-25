import { assertEquals } from "../test_assert.ts";
import {
  AccountAuthenticationError,
  processWhatsAppAccountSync,
  verifyWhatsAppAccountToken,
} from "./whatsapp_account_sync.ts";

Deno.test("WhatsApp token validation keeps secrets private and separates transient failures from invalid credentials", async (t) => {
  const oldFetch = globalThis.fetch;
  const oldId = Deno.env.get("META_APP_ID"),
    oldSecret = Deno.env.get("META_APP_SECRET");
  Deno.env.set("META_APP_ID", "128");
  Deno.env.set("META_APP_SECRET", "private-app-secret");
  const token = "private-whatsapp-test-token";
  try {
    await t.step("records verified expiry and number access", async () => {
      globalThis.fetch = (input, init) => {
        const u = new URL(String(input));
        if (u.pathname.endsWith("debug_token")) {
          assertEquals(u.searchParams.get("input_token"), token);
          assertEquals(
            (init?.headers as Record<string, string>).Authorization,
            "Bearer 128|private-app-secret",
          );
          return Promise.resolve(
            Response.json({
              data: {
                is_valid: true,
                app_id: "128",
                expires_at: 2000000000,
                scopes: [
                  "whatsapp_business_messaging",
                  "whatsapp_business_management",
                ],
              },
            }),
          );
        }
        assertEquals(u.pathname, "/v24.0/90000128");
        return Promise.resolve(Response.json({ id: "90000128" }));
      };
      assertEquals(
        await verifyWhatsAppAccountToken(token, "128", "90000128"),
        new Date(2000000000000).toISOString(),
      );
    });
    await t.step("unknown app fails without sending credentials", async () => {
      let calls = 0;
      globalThis.fetch = () => {
        calls++;
        throw new Error("Unexpected network");
      };
      let error: unknown;
      try {
        await verifyWhatsAppAccountToken(token, "129", "90000128");
      } catch (e) {
        error = e;
      }
      assertEquals(error instanceof AccountAuthenticationError, false);
      assertEquals(calls, 0);
    });
    for (
      const mode of [
        "invalid",
        "transient",
        "wrong-app",
        "expired",
        "missing-scopes",
      ]
    ) {
      await t.step(mode, async () => {
        globalThis.fetch = () =>
          Promise.resolve(
            mode === "transient"
              ? Response.json({ error: { code: 2 } }, { status: 503 })
              : Response.json({
                data: {
                  is_valid: mode !== "invalid",
                  app_id: mode === "wrong-app" ? "129" : "128",
                  expires_at: mode === "expired" ? 1 : 2000000000,
                  scopes: mode === "missing-scopes" ? [] : [
                    "whatsapp_business_messaging",
                    "whatsapp_business_management",
                  ],
                },
              }),
          );
        let error: unknown;
        try {
          await verifyWhatsAppAccountToken(token, "128", "90000128");
        } catch (e) {
          error = e;
        }
        assertEquals(error instanceof Error, true);
        assertEquals(
          error instanceof AccountAuthenticationError,
          ["invalid", "expired"].includes(mode),
        );
        assertEquals(String(error).includes(token), false);
        assertEquals(String(error).includes("private-app-secret"), false);
      });
    }
  } finally {
    globalThis.fetch = oldFetch;
    oldId === undefined
      ? Deno.env.delete("META_APP_ID")
      : Deno.env.set("META_APP_ID", oldId);
    oldSecret === undefined
      ? Deno.env.delete("META_APP_SECRET")
      : Deno.env.set("META_APP_SECRET", oldSecret);
  }
});

Deno.test("account operations reconcile durable requests without storing credential payloads", async (t) => {
  const org = "12800000-0000-4000-8000-000000000001",
    id = "12800000-0000-4000-8000-000000000002";
  const settings = {
    SUPABASE_URL: "https://db.example.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "test-key",
    NODE_CHATBOT_BRIDGE_ENABLED: "true",
    NODE_WHATSAPP_ACCOUNT_SYNC_ENABLED: "true",
    META_APP_ID: "128",
    META_APP_SECRET: "app-secret",
    NODE_CHATBOT_CONNECTIONS: JSON.stringify({
      [`${org}:90000128`]: {
        url: "https://node.example.invalid",
        company_id: "128",
        credential: "internal-test-credential-128-never-live",
      },
    }),
  };
  const previous = Object.fromEntries(
    Object.keys(settings).map((k) => [k, Deno.env.get(k)]),
  );
  const fetchBefore = globalThis.fetch;
  for (const [k, v] of Object.entries(settings)) Deno.env.set(k, v);
  async function scenario(
    status: string,
    attempts: number,
    ack: boolean,
    remoteFailure = false,
  ) {
    const writes: { path: string; body: unknown }[] = [],
      network: string[] = [];
    const op = {
      request_id: id,
      organization_id: org,
      organization_address: "90000128",
      action: "account-sync",
      phase: "account-sync",
      status,
      attempts,
      payload: { account_revision: "3" },
      next_attempt_at: null,
    };
    globalThis.fetch = (input, init) => {
      const u = new URL(String(input)),
        method = init?.method ?? "GET",
        body = init?.body ? JSON.parse(String(init.body)) : null;
      if (u.hostname === "db.example.invalid") {
        if (method !== "GET") writes.push({ path: u.pathname, body });
        if (u.pathname.endsWith("resolve_whatsapp_account_sync")) {
          return Promise.resolve(Response.json({
            organization_id: org,
            phone_number_id: "90000128",
            account_revision: "3",
            connected: true,
            access_token: "private-token-128-do-not-persist",
            token_expires_at: null,
            application_id: "128",
            waba_id: "128",
          }));
        }
        if (u.pathname.endsWith("complete_whatsapp_account_sync")) {
          return Promise.resolve(Response.json(true));
        }
        if (method === "GET" || u.searchParams.has("select")) {
          return Promise.resolve(Response.json(op));
        }
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      network.push(`${method} ${u.hostname}${u.pathname}`);
      if (u.hostname === "node.example.invalid") {
        if (u.pathname.endsWith("capabilities")) {
          return Promise.resolve(
            Response.json({ capabilities: ["openbsp-account-sync-v1"] }),
          );
        }
        if (method === "GET") {
          return Promise.resolve(
            ack
              ? Response.json({ data: { account_revision: "3" } })
              : Response.json({}, { status: 404 }),
          );
        }
        assertEquals(body.access_token, "private-token-128-do-not-persist");
        return Promise.resolve(
          remoteFailure
            ? Response.json({}, { status: 503 })
            : Response.json({ data: { account_revision: "3" } }),
        );
      }
      return Promise.resolve(
        Response.json(
          u.pathname.endsWith("debug_token")
            ? {
              data: {
                is_valid: true,
                app_id: "128",
                expires_at: 0,
                scopes: [
                  "whatsapp_business_management",
                  "whatsapp_business_messaging",
                ],
              },
            }
            : { id: "90000128" },
        ),
      );
    };
    await processWhatsAppAccountSync(id);
    assertEquals(JSON.stringify(writes).includes("private-token-128"), false);
    return { writes, network };
  }
  try {
    await t.step(
      "successful transfer stores only safe acknowledgment",
      async () => {
        const { writes } = await scenario("pending", 0, false);
        assertEquals(
          writes.some((w) => w.path.endsWith("complete_whatsapp_account_sync")),
          true,
        );
      },
    );
    await t.step(
      "ambiguous request looks up same ID and does not retransmit secrets",
      async () => {
        const { network, writes } = await scenario("reconciling", 1, true);
        assertEquals(network.length, 1);
        assertEquals(network[0].startsWith("GET node.example.invalid"), true);
        assertEquals(
          writes.some((w) => w.path.endsWith("complete_whatsapp_account_sync")),
          true,
        );
      },
    );
    await t.step(
      "retry exhaustion follows confirmed remote absence",
      async () => {
        const { network, writes } = await scenario("reconciling", 5, false);
        assertEquals(network.length, 1);
        assertEquals(
          writes.some((w) =>
            JSON.stringify(w.body).includes('"status":"failed"')
          ),
          true,
        );
      },
    );
    await t.step(
      "Node outage remains reconciling rather than reporting success",
      async () => {
        const { writes } = await scenario("pending", 0, false, true);
        assertEquals(
          writes.some((w) =>
            JSON.stringify(w.body).includes('"status":"reconciling"')
          ),
          true,
        );
        assertEquals(
          writes.some((w) => w.path.endsWith("complete_whatsapp_account_sync")),
          false,
        );
      },
    );
  } finally {
    globalThis.fetch = fetchBefore;
    for (const [k, v] of Object.entries(previous)) {
      v === undefined ? Deno.env.delete(k) : Deno.env.set(k, v);
    }
  }
});
