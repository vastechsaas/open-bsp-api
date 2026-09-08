import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import * as log from "../_shared/logger.ts";
import { createClient, createUnsecureClient } from "../_shared/supabase.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const purgeSchema = z.object({
  organization_id: z.string().uuid(),
  expected_name: z.string().min(1).max(250),
  password: z.string().min(1).max(1024),
  reason: z.string().trim().min(1).max(2000),
  request_id: z.string().uuid(),
});

function json(body: unknown, status: number): Response {
  return Response.json(body, {
    status,
    headers: { ...corsHeaders, "Cache-Control": "no-store" },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ message: "Method not allowed" }, 405);
  }

  try {
    const payload = purgeSchema.parse(await request.json());
    const caller = createClient(request);
    const { data: { user }, error: userError } = await caller.auth.getUser();

    if (userError || !user?.email) {
      return json({ message: "Invalid authentication" }, 401);
    }

    const { data: isPlatformAdmin, error: accessError } = await caller.rpc(
      "is_platform_admin",
    );
    if (accessError || !isPlatformAdmin) {
      return json({ message: "Platform administrator access required" }, 403);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseUrl || !anonKey) {
      throw new Error("Supabase auth is not configured");
    }

    const verifier = createSupabaseClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: passwordError } = await verifier.auth.signInWithPassword({
      email: user.email,
      password: payload.password,
    });
    if (passwordError) {
      return json({ message: "Password verification failed" }, 401);
    }

    const service = createUnsecureClient();
    const { data, error } = await service.rpc("purge_archived_organization", {
      p_actor_user_id: user.id,
      p_expected_name: payload.expected_name,
      p_organization_id: payload.organization_id,
      p_reason: payload.reason,
      p_request_id: payload.request_id,
    });
    if (error) throw error;

    return json(data, 200);
  } catch (error) {
    if (error instanceof z.ZodError || error instanceof SyntaxError) {
      return json({ message: "Invalid purge request" }, 400);
    }

    const databaseError = error as { code?: string; message?: string };
    if (databaseError.code === "42501") {
      return json({ message: databaseError.message }, 403);
    }
    if (databaseError.code === "P0002") {
      return json({ message: "Organization not found" }, 404);
    }
    if (databaseError.code === "22023") {
      return json({ message: databaseError.message }, 409);
    }

    log.error("Organization purge failed", error);
    return json({ message: "Organization purge failed" }, 500);
  }
});
