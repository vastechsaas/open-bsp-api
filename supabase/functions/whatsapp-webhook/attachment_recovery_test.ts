import { assertEquals } from "jsr:@std/assert";

type Handler = (request: Request) => Promise<Response>;

Deno.test("a signed live attachment is persisted through the durable RPC without waiting for Meta", async () => {
  const organizationId = "14700000-0000-4000-8000-000000000001";
  const env = {
    META_APP_ID: "fixture-app",
    META_APP_SECRET: "fixture-signing-secret",
    SUPABASE_URL: "https://attachment-fixture.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "fixture-service-key",
    WHATSAPP_ATTACHMENT_RECOVERY_ENABLED: "true",
    WHATSAPP_ATTACHMENT_RECOVERY_ORGANIZATIONS: organizationId,
  };
  const oldEnv = new Map(
    Object.keys(env).map((key) => [key, Deno.env.get(key)]),
  );
  const serve = Deno.serve;
  const fetcher = globalThis.fetch;
  const handlers: Handler[] = [];
  const persisted: unknown[] = [];
  const urls: string[] = [];
  try {
    for (const [name, value] of Object.entries(env)) Deno.env.set(name, value);
    Deno.serve = ((handler: Handler) => {
      handlers.push(handler);
      return {};
    }) as typeof Deno.serve;
    await import("./index.ts");
    assertEquals(handlers.length, 1);
    const webhook = handlers[0];
    globalThis.fetch = async (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      urls.push(url.hostname);
      assertEquals(url.hostname, "attachment-fixture.invalid");
      const path = url.pathname;
      if (path.endsWith("/organizations_addresses")) {
        return Response.json([{
          organization_id: organizationId,
          address: "14755500001",
          service: "whatsapp",
          status: "connected",
          extra: { waba_id: "fixture-waba" },
        }]);
      }
      if (path.endsWith("/rpc/persist_whatsapp_attachment_messages")) {
        persisted.push(await request.json());
        return Response.json(1);
      }
      if (
        path.endsWith("/whatsapp_integration_health") ||
        path.endsWith("/rpc/upsert_whatsapp_contact_addresses")
      ) {
        return new Response(null, { status: 204 });
      }
      throw new Error("Unexpected fixture request: " + path);
    };
    const body = JSON.stringify({
      object: "whatsapp_business_account",
      entry: [{
        id: "fixture-waba",
        changes: [{
          field: "messages",
          value: {
            messaging_product: "whatsapp",
            metadata: { phone_number_id: "14755500001" },
            contacts: [{ wa_id: "14755500002", profile: { name: "Fixture" } }],
            messages: [{
              id: "wamid.fixture-attachment",
              from: "14755500002",
              timestamp: "1767225600",
              type: "image",
              image: {
                id: "123456",
                mime_type: "image/jpeg",
                caption: "Fixture caption",
              },
            }],
          },
        }],
      }],
    });
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(env.META_APP_SECRET),
      {
        name: "HMAC",
        hash: "SHA-256",
      },
      false,
      ["sign"],
    );
    const sig = Array.from(
      new Uint8Array(
        await crypto.subtle.sign("HMAC", key, encoder.encode(body)),
      ),
      (byte) => byte.toString(16).padStart(2, "0"),
    ).join("");
    const request = (signature: string) =>
      new Request("https://attachment-fixture.invalid/webhook", {
        method: "POST",
        body,
        headers: { "X-Hub-Signature-256": "sha256=" + signature },
      });
    await webhook(request("invalid"));
    assertEquals(urls.length, 0);
    assertEquals((await webhook(request(sig))).status, 200);
    assertEquals(persisted.length, 1);
    const batch = persisted[0] as {
      p_messages: { content: { text: string; file: { uri: string } } }[];
    };
    assertEquals(batch.p_messages.length, 1);
    assertEquals(batch.p_messages[0].content.text, "Fixture caption");
    assertEquals(batch.p_messages[0].content.file.uri, "123456");
  } finally {
    Deno.serve = serve;
    globalThis.fetch = fetcher;
    for (const [name, value] of oldEnv) {
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
});
