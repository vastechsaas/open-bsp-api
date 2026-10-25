import { assertEquals } from "./test_assert.ts";

Deno.test("WhatsApp availability blocks session/API-key setup, profile changes and public onboarding before Meta I/O", async () => {
  const env = {
    SUPABASE_URL: "https://whatsapp-availability.invalid",
    SUPABASE_ANON_KEY: "test-anon",
    SUPABASE_SERVICE_ROLE_KEY: "test-service",
  };
  const previous = Object.fromEntries(
    Object.keys(env).map((key) => [key, Deno.env.get(key)]),
  );
  const originalFetch = globalThis.fetch;
  const originalServe = Deno.serve;
  const org = "12900000-0000-4000-8000-000000000001";
  let handler: ((request: Request) => Response | Promise<Response>) | undefined;
  let externalRequests = 0;
  const json = (value: unknown) =>
    new Response(JSON.stringify(value), {
      headers: { "content-type": "application/json" },
    });
  try {
    for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
    Deno.serve = ((captured: typeof handler) => {
      handler = captured;
      return {};
    }) as typeof Deno.serve;
    await import("../whatsapp-management/index.ts");
    Deno.serve = originalServe;
    if (!handler) throw new Error("Management handler not registered");
    globalThis.fetch = (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      if (url.hostname !== "whatsapp-availability.invalid") {
        externalRequests++;
        throw new Error("Meta must not be called while unavailable");
      }
      if (url.pathname.endsWith("/auth/v1/user")) {
        return Promise.resolve(json({ id: "owner" }));
      }
      if (url.pathname.endsWith("/api_keys")) {
        return Promise.resolve(json({ organization_id: org, role: "owner" }));
      }
      if (url.pathname.endsWith("/agents")) {
        return Promise.resolve(
          json({ organization_id: org, extra: { role: "owner" } }),
        );
      }
      if (url.pathname.endsWith("/rpc/is_integration_available")) {
        return Promise.resolve(json(false));
      }
      if (url.pathname.endsWith("/onboarding_tokens")) {
        return Promise.resolve(
          json({
            organization_id: org,
            status: "active",
            service: "whatsapp",
            expires_at: "2099-01-01T00:00:00Z",
          }),
        );
      }
      if (url.pathname.endsWith("/logs")) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      throw new Error(`Unexpected test request: ${url.pathname}`);
    };
    for (const authorization of ["Bearer eyJsession", "Bearer owner-api-key"]) {
      for (const path of ["/signup", "/profile/sync"]) {
        const response = await handler(
          new Request(`https://edge.invalid/whatsapp-management${path}`, {
            method: "POST",
            headers: { authorization, "content-type": "application/json" },
            body: JSON.stringify({
              organization_id: org,
              organization_address: "phone",
              code: "test-code",
              phone_number_id: "phone",
              waba_id: "waba",
            }),
          }),
        );
        assertEquals(response.status, 403);
        assertEquals(
          (await response.json()).cause.code,
          "INTEGRATION_UNAVAILABLE",
        );
      }
      const form = new FormData();
      form.set("organization_id", org);
      const profile = await handler(
        new Request("https://edge.invalid/whatsapp-management/profile", {
          method: "PATCH",
          headers: { authorization },
          body: form,
        }),
      );
      assertEquals(profile.status, 403);
    }
    assertEquals(
      (await handler(
        new Request(
          "https://edge.invalid/whatsapp-management/onboard?token=test-token",
        ),
      )).status,
      403,
    );
    assertEquals(
      (await handler(
        new Request("https://edge.invalid/whatsapp-management/onboard", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            token: "test-token",
            code: "test-code",
            phone_number_id: "phone",
            waba_id: "waba",
          }),
        }),
      )).status,
      403,
    );
    assertEquals(externalRequests, 0);
  } finally {
    globalThis.fetch = originalFetch;
    Deno.serve = originalServe;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
