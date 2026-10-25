import { assertEquals } from "./test_assert.ts";

type Handler = (request: Request) => Response | Promise<Response>;
type Call = { url: URL; method: string; body: Record<string, unknown> | null };

Deno.test("Instagram selective integration preserves the staging contract", async (t) => {
  const env = {
    SUPABASE_URL: "https://instagram-test.invalid",
    SUPABASE_ANON_KEY: "test-anon",
    SUPABASE_SERVICE_ROLE_KEY: "test-service",
    EDGE_FUNCTIONS_TOKEN: "test-internal-dispatch",
    INSTAGRAM_APP_ID: "test-app",
    INSTAGRAM_APP_SECRET: "test-app-secret",
    INSTAGRAM_WEBHOOK_APP_SECRET: "test-webhook-app-secret",
    INSTAGRAM_WEBHOOK_SIGNATURE_DIAGNOSTICS: "false",
    INSTAGRAM_VERIFY_TOKEN: "test-verify",
  };
  const oldEnv = new Map(
    Object.keys(env).map((key) => [key, Deno.env.get(key)]),
  );
  const originalServe = Deno.serve;
  const originalFetch = globalThis.fetch;
  const handlers: Handler[] = [];
  const calls: Call[] = [];
  const org = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  let active = true;
  let available = true;
  let disableDuringExchange = false;
  let graphCode: number | undefined;
  let profileCode: number | undefined;
  let nonJsonProfileError = false;
  let pendingMember = false;
  let apiKeyRole = "owner";
  const row = {
    organization_id: org,
    address: "business",
    service: "instagram",
    status: "connected",
    created_at: "2026-01-01T00:00:00Z",
    extra: {
      access_token: "test-account-secret",
      username: "test",
      needs_reauth: "2026-01-01T00:00:00Z",
    },
  };
  const json = (value: unknown, status = 200) =>
    new Response(JSON.stringify(value), {
      status,
      headers: { "content-type": "application/json" },
    });
  try {
    for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
    Deno.serve = ((handler: Handler) => {
      handlers.push(handler);
      return {};
    }) as typeof Deno.serve;
    await import("../instagram-dispatcher/index.ts");
    await import("../instagram-webhook/index.ts");
    await import("../instagram-management/index.ts");
    Deno.serve = originalServe;
    const [dispatch, webhook, management] = handlers;
    assertEquals(handlers.length, 3);

    globalThis.fetch = async (input, init) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      const text = await request.text();
      const body = text && request.headers.get("content-type")?.includes("json")
        ? JSON.parse(text) as Record<string, unknown>
        : null;
      calls.push({ url, method: request.method, body });
      if (url.hostname === "instagram-test.invalid") {
        if (url.pathname.endsWith("/rpc/is_organization_active")) {
          return json(active);
        }
        if (url.pathname.endsWith("/rpc/is_integration_available")) {
          return json(available);
        }
        if (url.pathname.endsWith("/api_keys")) {
          return json({ organization_id: org, role: apiKeyRole });
        }
        if (url.pathname.endsWith("/auth/v1/user")) {
          return json({ id: "test-user" });
        }
        if (url.pathname.endsWith("/agents")) {
          return json({
            organization_id: org,
            extra: {
              role: "owner",
              invitation: { status: pendingMember ? "pending" : "accepted" },
            },
          });
        }
        if (url.pathname.endsWith("/organization_lifecycle")) {
          return json(active ? [{ organization_id: org }] : []);
        }
        if (
          url.pathname.endsWith("/onboarding_tokens") &&
          request.method === "GET"
        ) {
          return json({
            organization_id: org,
            service: "instagram",
            status: "active",
            expires_at: "2099-01-01T00:00:00Z",
          });
        }
        if (url.pathname.endsWith("/organizations_addresses")) {
          if (request.method === "GET") {
            return url.searchParams.get("select") === "extra->>access_token"
              ? json({ access_token: row.extra.access_token })
              : json(
                url.searchParams.has("address") &&
                  url.searchParams.get("address")?.startsWith("in.")
                  ? [row]
                  : row,
              );
          }
          if (request.method === "POST") {
            return json({ ...row, ...body });
          }
        }
        if (
          url.pathname.endsWith("/contacts_addresses") &&
          request.method === "GET"
        ) return json([]);
        if (request.method === "PATCH" || request.method === "POST") {
          return new Response(null, { status: 204 });
        }
      }
      if (url.hostname === "api.instagram.com") {
        if (disableDuringExchange) available = false;
        return json({ access_token: "short-secret", user_id: "business" });
      }
      if (url.hostname === "graph.instagram.com") {
        if (url.pathname.endsWith("/messages")) {
          return graphCode
            ? json({ error: { code: graphCode, message: "Test failure" } }, 400)
            : json({ message_id: "ig-sent-1" });
        }
        if (url.pathname.endsWith("/customer")) {
          if (nonJsonProfileError) {
            return new Response("Unavailable", { status: 503 });
          }
          return profileCode
            ? json({ error: { code: profileCode } }, 400)
            : json({ name: "Customer", username: "customer" });
        }
        if (url.pathname.endsWith("/access_token")) {
          return json({ access_token: "long-secret", expires_in: 5_184_000 });
        }
        if (url.pathname.endsWith("/me")) {
          return json({ user_id: "business", username: "test" });
        }
        if (url.pathname.endsWith("/subscribed_apps")) {
          return json({ success: true });
        }
      }
      throw new Error(`Unexpected test request: ${request.method} ${url}`);
    };
    const reset = () => {
      calls.length = 0;
      active = true;
      available = true;
      disableDuringExchange = false;
      graphCode = undefined;
      profileCode = undefined;
      nonJsonProfileError = false;
      pendingMember = false;
      apiKeyRole = "owner";
    };
    const message = (overrides: Record<string, unknown> = {}) => ({
      id: "message-1",
      organization_id: org,
      organization_address: "business",
      contact_address: "customer",
      service: "instagram",
      direction: "outgoing",
      content: { version: "1", type: "text", kind: "text", text: "Hello" },
      status: {},
      ...overrides,
    });
    const dispatchRequest = (
      record: unknown,
      token = env.EDGE_FUNCTIONS_TOKEN,
    ) =>
      new Request("https://edge.invalid/instagram-dispatcher", {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ record }),
      });
    let dispatchTestModule = 0;
    const dispatchWithConfig = async (
      internalToken: string | undefined,
      serviceRoleToken: string | undefined,
    ): Promise<Handler> => {
      let handler: Handler | undefined;
      for (
        const [name, value] of [
          ["EDGE_FUNCTIONS_TOKEN", internalToken],
          ["SUPABASE_SERVICE_ROLE_KEY", serviceRoleToken],
        ] as const
      ) {
        if (value === undefined) Deno.env.delete(name);
        else Deno.env.set(name, value);
      }
      Deno.serve = ((captured: Handler) => {
        handler = captured;
        return {};
      }) as typeof Deno.serve;
      try {
        await import(
          `../instagram-dispatcher/index.ts?dispatch-test=${++dispatchTestModule}`
        );
      } finally {
        Deno.serve = originalServe;
        Deno.env.set("EDGE_FUNCTIONS_TOKEN", env.EDGE_FUNCTIONS_TOKEN);
        Deno.env.set(
          "SUPABASE_SERVICE_ROLE_KEY",
          env.SUPABASE_SERVICE_ROLE_KEY,
        );
      }
      if (!handler) throw new Error("Dispatcher handler was not registered");
      return handler;
    };
    const flags = () =>
      calls.filter((call) =>
        call.method === "PATCH" &&
        call.url.pathname.endsWith("/organizations_addresses")
      );
    const messageWrites = () =>
      calls.filter((call) =>
        call.method === "PATCH" && call.url.pathname.endsWith("/messages")
      );
    const webhookRequest = async (
      valid = true,
      signingSecret = env.INSTAGRAM_WEBHOOK_APP_SECRET,
      appId?: string,
      options: { text?: string; utf8Bom?: boolean } = {},
    ) => {
      const payload = JSON.stringify({
        object: "instagram",
        entry: [{
          id: "business",
          messaging: [{
            sender: { id: "customer" },
            recipient: { id: "business" },
            timestamp: 1_700_000_000_000,
            message: { mid: "ig-incoming-1", text: options.text ?? "Hi" },
          }],
        }],
      });
      const encoded = new TextEncoder().encode(payload);
      const body = new Uint8Array(encoded.length + (options.utf8Bom ? 3 : 0));
      if (options.utf8Bom) body.set([0xef, 0xbb, 0xbf]);
      body.set(encoded, options.utf8Bom ? 3 : 0);
      const key = await crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode(signingSecret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
      );
      const signature = Array.from(
        new Uint8Array(
          await crypto.subtle.sign("HMAC", key, body),
        ),
      )
        .map((byte) => byte.toString(16).padStart(2, "0")).join("");
      const url = new URL("https://edge.invalid/instagram-webhook");
      if (appId) url.searchParams.set("app_id", appId);
      return new Request(url, {
        method: "POST",
        headers: {
          "X-Hub-Signature-256": `sha256=${valid ? signature : "invalid"}`,
        },
        body,
      });
    };
    let webhookTestModule = 0;
    const webhookWithConfig = async (
      ids: string,
      signingSecrets: string | undefined,
      diagnostics = false,
      loginSecrets = env.INSTAGRAM_APP_SECRET,
    ): Promise<Handler> => {
      let handler: Handler | undefined;
      Deno.env.set("INSTAGRAM_APP_ID", ids);
      Deno.env.set("INSTAGRAM_APP_SECRET", loginSecrets);
      Deno.env.set(
        "INSTAGRAM_WEBHOOK_SIGNATURE_DIAGNOSTICS",
        String(diagnostics),
      );
      if (signingSecrets === undefined) {
        Deno.env.delete("INSTAGRAM_WEBHOOK_APP_SECRET");
      } else Deno.env.set("INSTAGRAM_WEBHOOK_APP_SECRET", signingSecrets);
      Deno.serve = ((captured: Handler) => {
        handler = captured;
        return {};
      }) as typeof Deno.serve;
      try {
        await import(
          `../instagram-webhook/index.ts?signing-test=${++webhookTestModule}`
        );
      } finally {
        Deno.serve = originalServe;
        Deno.env.set("INSTAGRAM_APP_ID", env.INSTAGRAM_APP_ID);
        Deno.env.set("INSTAGRAM_APP_SECRET", env.INSTAGRAM_APP_SECRET);
        Deno.env.set(
          "INSTAGRAM_WEBHOOK_SIGNATURE_DIAGNOSTICS",
          env.INSTAGRAM_WEBHOOK_SIGNATURE_DIAGNOSTICS,
        );
        Deno.env.set(
          "INSTAGRAM_WEBHOOK_APP_SECRET",
          env.INSTAGRAM_WEBHOOK_APP_SECRET,
        );
      }
      if (!handler) throw new Error("Webhook handler was not registered");
      return handler;
    };
    const inboundWrites = () =>
      calls.filter((call) =>
        call.method === "POST" && call.url.pathname.endsWith("/messages")
      );

    await t.step(
      "custom dispatch credential rejects service-role, Meta, missing and malformed credentials before any I/O",
      async () => {
        reset();
        for (
          const token of [
            env.SUPABASE_SERVICE_ROLE_KEY,
            row.extra.access_token,
            "wrong",
          ]
        ) {
          assertEquals(
            (await dispatch(dispatchRequest(message(), token))).status,
            401,
          );
        }
        for (
          const authorization of [
            undefined,
            env.EDGE_FUNCTIONS_TOKEN,
            "Bearer ",
            `Basic ${env.EDGE_FUNCTIONS_TOKEN}`,
          ]
        ) {
          assertEquals(
            (await dispatch(
              new Request("https://edge.invalid/instagram-dispatcher", {
                method: "POST",
                headers: authorization === undefined ? {} : { authorization },
                body: "not-json",
              }),
            )).status,
            401,
          );
        }
        assertEquals(calls.length, 0);
      },
    );
    await t.step(
      "upstream dispatch credential is used only when the custom setting is absent",
      async () => {
        const legacy = await dispatchWithConfig(
          undefined,
          env.SUPABASE_SERVICE_ROLE_KEY,
        );
        reset();
        assertEquals((await legacy(dispatchRequest(message()))).status, 401);
        assertEquals(calls.length, 0);
        assertEquals(
          (await legacy(
            dispatchRequest(message(), env.SUPABASE_SERVICE_ROLE_KEY),
          )).status,
          200,
        );
        assertEquals(messageWrites()[0].body?.external_id, "ig-sent-1");
      },
    );
    await t.step(
      "an explicitly empty dispatch credential never falls back to service role",
      async () => {
        const disabled = await dispatchWithConfig(
          "",
          env.SUPABASE_SERVICE_ROLE_KEY,
        );
        reset();
        assertEquals(
          (await disabled(
            dispatchRequest(message(), env.SUPABASE_SERVICE_ROLE_KEY),
          )).status,
          401,
        );
        assertEquals(
          (await disabled(dispatchRequest(message(), ""))).status,
          401,
        );
        assertEquals(calls.length, 0);
      },
    );
    await t.step(
      "missing dispatch credentials fail closed even without an authorization header",
      async () => {
        const disabled = await dispatchWithConfig(undefined, undefined);
        reset();
        assertEquals(
          (await disabled(
            new Request("https://edge.invalid/instagram-dispatcher", {
              method: "POST",
              body: "not-json",
            }),
          )).status,
          401,
        );
        assertEquals(calls.length, 0);
      },
    );
    await t.step(
      "unauthorized dispatch and archived organizations cannot send",
      async () => {
        reset();
        assertEquals(
          (await dispatch(dispatchRequest(message(), "wrong"))).status,
          401,
        );
        assertEquals(calls.length, 0);
        active = false;
        assertEquals((await dispatch(dispatchRequest(message()))).status, 202);
        assertEquals(
          calls.some((call) => call.url.hostname === "graph.instagram.com"),
          false,
        );
      },
    );
    await t.step(
      "text sends use Instagram-only account lookup and retain accepted status",
      async () => {
        reset();
        assertEquals((await dispatch(dispatchRequest(message()))).status, 200);
        const lookup = calls.find((call) =>
          call.url.pathname.endsWith("/organizations_addresses")
        )!;
        assertEquals(
          lookup.url.searchParams.get("organization_id"),
          `eq.${org}`,
        );
        assertEquals(lookup.url.searchParams.get("service"), "eq.instagram");
        assertEquals(messageWrites()[0].body?.external_id, "ig-sent-1");
        assertEquals(flags().length, 0);
      },
    );
    await t.step(
      "media captions retain the existing two-payload contract",
      async () => {
        reset();
        await dispatch(dispatchRequest(message({
          content: {
            version: "1",
            type: "file",
            kind: "image",
            file: { uri: "https://cdn.invalid/image.jpg" },
            text: "Caption",
          },
        })));
        const sends = calls.filter((call) =>
          call.url.hostname === "graph.instagram.com"
        );
        assertEquals(sends.length, 2);
        assertEquals(sends[1].body?.message, { text: "Caption" });
      },
    );
    await t.step(
      "revoked sends mark only this tenant's Instagram connection and stop retry",
      async () => {
        reset();
        graphCode = 190;
        await dispatch(dispatchRequest(message()));
        assertEquals(flags().length, 1);
        assertEquals(
          flags()[0].url.searchParams.get("organization_id"),
          `eq.${org}`,
        );
        assertEquals(flags()[0].url.searchParams.get("address"), "eq.business");
        assertEquals(
          flags()[0].url.searchParams.get("service"),
          "eq.instagram",
        );
        assertEquals(
          flags()[0].url.searchParams.get("extra->>access_token"),
          "eq.test-account-secret",
        );
        assertEquals(Object.keys(flags()[0].body?.extra as object), [
          "needs_reauth",
        ]);
        assertEquals(
          !!(messageWrites()[0].body?.status as Record<string, unknown>).failed,
          true,
        );
      },
    );
    await t.step(
      "rate limits remain retryable and do not request reconnection",
      async () => {
        reset();
        graphCode = 4;
        let rejected = false;
        try {
          await dispatch(dispatchRequest(message()));
        } catch {
          rejected = true;
        }
        assertEquals(rejected, true);
        assertEquals(flags().length, 0);
        assertEquals(
          (messageWrites()[0].body?.status as Record<string, unknown>).failed,
          undefined,
        );
      },
    );
    await t.step(
      "revoked read/typing actions also request reconnection",
      async () => {
        reset();
        graphCode = 190;
        try {
          await dispatch(
            dispatchRequest(
              message({
                direction: "incoming",
                status: { read: new Date().toISOString() },
              }),
            ),
          );
        } catch { /* original error stays retry-visible */ }
        assertEquals(flags().length, 1);
      },
    );
    await t.step(
      "webhook verification and invalid signatures do not touch storage",
      async () => {
        reset();
        const verified = await webhook(
          new Request(
            "https://edge.invalid/instagram-webhook?hub.mode=subscribe&hub.verify_token=test-verify&hub.challenge=challenge",
          ),
        );
        assertEquals(await verified.text(), "challenge");
        await webhook(await webhookRequest(false));
        assertEquals(calls.length, 0);
      },
    );
    await t.step(
      "dedicated webhook secret accepts inbound messages; OAuth secret does not",
      async () => {
        reset();
        await webhook(await webhookRequest());
        assertEquals(inboundWrites().length, 1);
        reset();
        await webhook(await webhookRequest(true, env.INSTAGRAM_APP_SECRET));
        assertEquals(calls.length, 0);
      },
    );
    await t.step("tampered payloads remain rejected", async () => {
      reset();
      const signed = await webhookRequest();
      const body = (await signed.text()).replace('"Hi"', '"Tampered"');
      await webhook(
        new Request(signed.url, {
          method: "POST",
          headers: signed.headers,
          body,
        }),
      );
      assertEquals(calls.length, 0);
    });
    await t.step(
      "raw UTF-8 bytes are verified before decoding a BOM",
      async () => {
        reset();
        await webhook(
          await webhookRequest(
            true,
            env.INSTAGRAM_WEBHOOK_APP_SECRET,
            undefined,
            {
              text: "سلام 👋",
              utf8Bom: true,
            },
          ),
        );
        const writes = inboundWrites();
        assertEquals(writes.length, 1);
        const messages = writes[0].body as unknown as Array<{
          content: { text: string };
        }>;
        assertEquals(messages[0].content.text, "سلام 👋");
      },
    );
    await t.step(
      "signature diagnostics reveal format only, never credentials",
      async () => {
        reset();
        const malformedSecret = ` "${env.INSTAGRAM_WEBHOOK_APP_SECRET}" `;
        const malformed = await webhookWithConfig(
          env.INSTAGRAM_APP_ID,
          malformedSecret,
        );
        const originalWarn = console.warn;
        const warnings: unknown[][] = [];
        console.warn = (...args: unknown[]) => warnings.push(args);
        try {
          const request = await webhookRequest();
          const signature = request.headers.get("X-Hub-Signature-256")!;
          await malformed(request);
          assertEquals(calls.length, 0);
          const details = warnings[0][2] as Record<string, unknown>;
          assertEquals(details.signing_secret_source, "dedicated");
          assertEquals(details.signing_secret_has_outer_whitespace, true);
          assertEquals(details.signing_secret_has_wrapping_quotes, true);
          assertEquals(details.signing_secret_is_32_char_hex, false);
          assertEquals(details.signature_is_sha256_hex, true);
          assertEquals(details.signature_matches_oauth_secret, undefined);
          const serialized = JSON.stringify(warnings);
          assertEquals(
            serialized.includes(env.INSTAGRAM_WEBHOOK_APP_SECRET),
            false,
          );
          assertEquals(serialized.includes(env.INSTAGRAM_APP_SECRET), false);
          assertEquals(serialized.includes(signature.slice(7)), false);
          assertEquals(serialized.includes("ig-incoming-1"), false);
        } finally {
          console.warn = originalWarn;
        }
      },
    );
    await t.step(
      "opt-in comparison uses exact bytes without accepting the diagnostic key or logging data",
      async () => {
        const diagnostic = await webhookWithConfig(
          env.INSTAGRAM_APP_ID,
          env.INSTAGRAM_WEBHOOK_APP_SECRET,
          true,
        );
        const originalWarn = console.warn;
        const warnings: unknown[][] = [];
        console.warn = (...args: unknown[]) => warnings.push(args);
        try {
          reset();
          const request = await webhookRequest(
            true,
            env.INSTAGRAM_APP_SECRET,
            undefined,
            { text: "private diagnostic message سلام", utf8Bom: true },
          );
          const signature = request.headers.get("X-Hub-Signature-256")!;
          await diagnostic(request);
          assertEquals(calls.length, 0);
          const details = warnings[0][2] as Record<string, unknown>;
          assertEquals(details.signature_matches_configured_secret, false);
          assertEquals(details.oauth_secret_available, true);
          assertEquals(details.signature_matches_oauth_secret, true);
          const serialized = JSON.stringify(warnings);
          for (
            const sensitive of [
              env.INSTAGRAM_APP_SECRET,
              env.INSTAGRAM_WEBHOOK_APP_SECRET,
              signature.slice(7),
              "private diagnostic message",
              "ig-incoming-1",
            ]
          ) assertEquals(serialized.includes(sensitive), false);
          warnings.length = 0;
          await diagnostic(await webhookRequest(true, "unrelated-secret"));
          assertEquals(calls.length, 0);
          assertEquals(
            (warnings[0][2] as Record<string, unknown>)
              .signature_matches_oauth_secret,
            false,
          );
        } finally {
          console.warn = originalWarn;
        }
      },
    );
    await t.step(
      "diagnostic comparisons never try a different app or a misaligned OAuth key list",
      async () => {
        const multi = await webhookWithConfig(
          "test-app|second-app",
          `${env.INSTAGRAM_WEBHOOK_APP_SECRET}|second-signing-secret`,
          true,
          `${env.INSTAGRAM_APP_SECRET}|second-login-secret`,
        );
        const misaligned = await webhookWithConfig(
          "test-app|second-app",
          `${env.INSTAGRAM_WEBHOOK_APP_SECRET}|second-signing-secret`,
          true,
        );
        const originalWarn = console.warn;
        const warnings: unknown[][] = [];
        console.warn = (...args: unknown[]) => warnings.push(args);
        try {
          reset();
          await multi(
            await webhookRequest(true, env.INSTAGRAM_APP_SECRET, "second-app"),
          );
          assertEquals(
            (warnings[0][2] as Record<string, unknown>)
              .signature_matches_oauth_secret,
            false,
          );
          warnings.length = 0;
          await multi(
            await webhookRequest(true, "second-login-secret", "second-app"),
          );
          assertEquals(
            (warnings[0][2] as Record<string, unknown>)
              .signature_matches_oauth_secret,
            true,
          );
          warnings.length = 0;
          await misaligned(
            await webhookRequest(true, env.INSTAGRAM_APP_SECRET, "second-app"),
          );
          const details = warnings[0][2] as Record<string, unknown>;
          assertEquals(details.oauth_secret_available, false);
          assertEquals(details.signature_matches_oauth_secret, null);
          assertEquals(calls.length, 0);
        } finally {
          console.warn = originalWarn;
        }
      },
    );
    await t.step(
      "legacy single-secret deployments remain compatible",
      async () => {
        reset();
        const legacy = await webhookWithConfig(env.INSTAGRAM_APP_ID, undefined);
        await legacy(await webhookRequest(true, env.INSTAGRAM_APP_SECRET));
        assertEquals(inboundWrites().length, 1);
      },
    );
    await t.step(
      "an explicitly empty signing secret fails closed",
      async () => {
        reset();
        const disabled = await webhookWithConfig(env.INSTAGRAM_APP_ID, "");
        await disabled(await webhookRequest(true, env.INSTAGRAM_APP_SECRET));
        assertEquals(calls.length, 0);
      },
    );
    await t.step(
      "multi-app callbacks use only their corresponding webhook signing secret",
      async () => {
        const multi = await webhookWithConfig(
          "test-app|second-app",
          `${env.INSTAGRAM_WEBHOOK_APP_SECRET}|second-signing-secret`,
        );
        reset();
        await multi(await webhookRequest());
        assertEquals(inboundWrites().length, 1);
        reset();
        await multi(
          await webhookRequest(true, "second-signing-secret", "second-app"),
        );
        assertEquals(inboundWrites().length, 1);
        reset();
        await multi(
          await webhookRequest(
            true,
            env.INSTAGRAM_WEBHOOK_APP_SECRET,
            "second-app",
          ),
        );
        assertEquals(calls.length, 0);
        await multi(
          await webhookRequest(true, "second-signing-secret", "absent"),
        );
        assertEquals(calls.length, 0);
      },
    );
    await t.step(
      "mismatched app and signing-secret lists fail closed",
      async () => {
        reset();
        const invalid = await webhookWithConfig(
          "test-app|second-app",
          env.INSTAGRAM_WEBHOOK_APP_SECRET,
        );
        await invalid(await webhookRequest());
        assertEquals(calls.length, 0);
      },
    );
    await t.step(
      "a revoked profile token still allows inbound messages to land",
      async () => {
        reset();
        profileCode = 190;
        assertEquals((await webhook(await webhookRequest())).status, 200);
        assertEquals(flags().length, 1);
        const write = calls.find((call) =>
          call.method === "POST" && call.url.pathname.endsWith("/messages")
        )!;
        assertEquals(write.url.searchParams.get("on_conflict"), "external_id");
        assertEquals(
          (write.body as unknown as Array<{ direction: string }>)[0].direction,
          "incoming",
        );
      },
    );
    await t.step(
      "non-token profile failures do not incorrectly flag the account",
      async () => {
        reset();
        nonJsonProfileError = true;
        assertEquals((await webhook(await webhookRequest())).status, 200);
        assertEquals(flags().length, 0);
      },
    );
    await t.step(
      "archived organizations do not ingest Instagram webhooks",
      async () => {
        reset();
        active = false;
        assertEquals((await webhook(await webhookRequest())).status, 200);
        assertEquals(
          calls.some((call) => call.url.hostname === "graph.instagram.com"),
          false,
        );
        assertEquals(
          calls.some((call) =>
            call.method === "POST" && call.url.pathname.endsWith("/messages")
          ),
          false,
        );
      },
    );
    const signup = (organization_id = org) =>
      new Request("https://edge.invalid/instagram-management/signup", {
        method: "POST",
        headers: {
          authorization: "Bearer owner-api-key",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          organization_id,
          code: "test-code",
          redirect_uri: "https://ui.invalid/oauth/instagram",
        }),
      });
    await t.step(
      "disabled integration blocks authenticated and public callbacks before external work",
      async () => {
        for (const jwt of [true, false]) {
          reset();
          available = false;
          const request = signup();
          if (jwt) request.headers.set("Authorization", "Bearer eyJtest");
          assertEquals((await management(request)).status, 403);
          assertEquals(
            calls.some((call) => call.url.hostname.endsWith("instagram.com")),
            false,
          );
        }
        reset();
        available = false;
        const response = await management(
          new Request("https://edge.invalid/instagram-management/onboard", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              token: "onboard-token",
              code: "test-code",
              redirect_uri: "https://ui.invalid/onboard/instagram/callback",
            }),
          }),
        );
        assertEquals(response.status, 403);
        assertEquals(
          calls.some((call) => call.url.hostname.endsWith("instagram.com")),
          false,
        );
        assertEquals(
          calls.some((call) =>
            call.method === "PATCH" &&
            call.url.pathname.endsWith("/onboarding_tokens")
          ),
          false,
        );
        assertEquals(
          (await management(
            new Request(
              "https://edge.invalid/instagram-management/onboard?token=onboard-token",
            ),
          )).status,
          403,
        );
      },
    );
    await t.step(
      "already accepted registration may finish after disabling",
      async () => {
        reset();
        disableDuringExchange = true;
        assertEquals((await management(signup())).status, 200);
        assertEquals(available, false);
        assertEquals(
          calls.filter((call) =>
            call.url.pathname.endsWith("/rpc/is_integration_available")
          ).length,
          1,
        );
      },
    );
    await t.step("API-key organization binding is retained", async () => {
      reset();
      assertEquals(
        (await management(signup("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")))
          .status,
        403,
      );
      assertEquals(
        calls.some((call) => call.url.hostname.endsWith("instagram.com")),
        false,
      );
    });
    await t.step(
      "non-owner API keys and pending members cannot connect",
      async () => {
        reset();
        apiKeyRole = "member";
        assertEquals((await management(signup())).status, 403);
        reset();
        pendingMember = true;
        const request = signup();
        request.headers.set("Authorization", "Bearer eyJtest");
        assertEquals((await management(request)).status, 403);
        assertEquals(
          calls.some((call) => call.url.hostname.endsWith("instagram.com")),
          false,
        );
      },
    );
    await t.step(
      "archived organizations cannot start OAuth exchange",
      async () => {
        reset();
        active = false;
        assertEquals((await management(signup())).status, 403);
        assertEquals(
          calls.some((call) => call.url.hostname.endsWith("instagram.com")),
          false,
        );
      },
    );
    await t.step(
      "successful reconnection clears stale flag without exposing tokens",
      async () => {
        reset();
        const response = await management(signup());
        assertEquals(response.status, 200);
        const account = await response.json();
        assertEquals(account.extra.access_token, undefined);
        assertEquals(account.extra.needs_reauth, null);
        const exchange = calls.find((call) =>
          call.url.hostname === "graph.instagram.com" &&
          call.url.pathname.endsWith("/access_token")
        )!;
        assertEquals(
          exchange.url.searchParams.get("client_secret"),
          env.INSTAGRAM_APP_SECRET,
        );
        const saved = calls.find((call) =>
          call.method === "POST" &&
          call.url.pathname.endsWith("/organizations_addresses")
        )!;
        assertEquals(
          (saved.body?.extra as Record<string, unknown>).access_token,
          "long-secret",
        );
      },
    );
    await t.step(
      "public onboarding also omits the OAuth access token",
      async () => {
        reset();
        const response = await management(
          new Request("https://edge.invalid/instagram-management/onboard", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              token: "onboard-token",
              code: "test-code",
              redirect_uri: "https://ui.invalid/onboard/instagram/callback",
            }),
          }),
        );
        assertEquals(response.status, 200);
        const account = await response.json();
        assertEquals(account.address, "business");
        assertEquals(account.extra.access_token, undefined);
      },
    );
  } finally {
    Deno.serve = originalServe;
    globalThis.fetch = originalFetch;
    for (const [key, value] of oldEnv) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
