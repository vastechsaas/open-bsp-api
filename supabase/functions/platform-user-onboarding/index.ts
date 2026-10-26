import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, createUnsecureClient } from "../_shared/supabase.ts";
import { execute, payloadSchema, SafeFailure } from "./core.ts";
import {
  accountSetupDependencies,
  assertAccountSetupConfigured,
} from "./runtime.ts";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
};
const json = (body: unknown, status = 200) =>
  Response.json(body, {
    status,
    headers: { ...cors, "Cache-Control": "no-store" },
  });
Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }
  if (request.method !== "POST") {
    return json({ code: "METHOD_NOT_ALLOWED" }, 405);
  }
  try {
    if (Number(request.headers.get("content-length")) > 10000) {
      return json({ code: "ONBOARDING_INVALID_REQUEST" }, 400);
    }
    const raw = await request.text();
    if (raw.length > 10000) {
      return json({ code: "ONBOARDING_INVALID_REQUEST" }, 400);
    }
    const parsed = payloadSchema.safeParse(JSON.parse(raw));
    if (!parsed.success) {
      return json({ code: "ONBOARDING_INVALID_REQUEST" }, 400);
    }
    const payload = parsed.data;
    let actor = "00000000-0000-0000-0000-000000000000";
    if (payload.action !== "preview") {
      if (!request.headers.get("Authorization")?.startsWith("Bearer ")) {
        return json({ code: "ONBOARDING_UNAUTHENTICATED" }, 401);
      }
      const client = createClient(request);
      const { data: { user }, error } = await client.auth.getUser();
      if (error || !user) {
        return json({ code: "ONBOARDING_UNAUTHENTICATED" }, 401);
      }
      actor = user.id;
      if (payload.action !== "complete") {
        const { data, error } = await client.rpc("is_platform_admin");
        if (error || !data) return json({ code: "ONBOARDING_FORBIDDEN" }, 403);
      }
    }
    assertAccountSetupConfigured(payload.action);
    return json(
      await execute(
        payload,
        accountSetupDependencies(
          createUnsecureClient(),
          actor,
          payload.action === "complete" ? payload : undefined,
        ),
      ),
    );
  } catch (error) {
    // Auth errors must never be logged: they may contain credentials.
    if (error instanceof SafeFailure) {
      return json({ code: error.code }, error.status);
    }
    if (error instanceof SyntaxError) {
      return json({ code: "ONBOARDING_INVALID_REQUEST" }, 400);
    }
    return json({ code: "ONBOARDING_UNAVAILABLE" }, 503);
  }
});
