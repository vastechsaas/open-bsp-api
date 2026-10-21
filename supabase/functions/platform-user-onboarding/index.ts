import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, createUnsecureClient } from "../_shared/supabase.ts";
import {
  digest,
  execute,
  type Operation,
  payloadSchema,
  SafeFailure,
} from "./core.ts";
import type { Json } from "../_shared/db_types.ts";

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
    const service = createUnsecureClient();
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
    const command = async (command: string, input: Record<string, unknown>) => {
      // Recipient password setup needs private status for recovery, but is never
      // allowed to use the administrator status path or read another operation.
      const name = payload.action === "complete" &&
          (command === "status" || command === "failed")
        ? `complete_${command}`
        : command;
      const { data, error } = await service.rpc("platform_onboarding_command", {
        p_actor: actor,
        p_command: name,
        p_payload: JSON.parse(
          JSON.stringify({
            ...input,
            ...(payload.action === "complete"
              ? { context_hash: await digest(payload.context) }
              : {}),
          }),
        ) as Json,
      });
      if (error) {
        const code = error.message.includes("capacity has been reached")
          ? "ONBOARDING_CAPACITY_REACHED"
          : error.message.includes("already exists")
          ? "ONBOARDING_MEMBERSHIP_EXISTS"
          : error.message.match(/(?:ONBOARDING|TEAM_MEMBER)_[A-Z_]+/)?.[0] ??
            "ONBOARDING_INVALID_REQUEST";
        throw new SafeFailure(code, error.code === "42501" ? 403 : 409);
      }
      return data as unknown as Operation;
    };
    const url = Deno.env.get("SUPABASE_URL")!;
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const callback = Deno.env.get("PLATFORM_ONBOARDING_CALLBACK_URL") ?? "";
    // Explicit protected deployment configuration; never infer Main's callback.
    if (
      payload.action !== "preview" && payload.action !== "status" &&
      payload.action !== "complete" &&
      callback !== "https://vistagalaxy.vastech.biz/onboard/set-password"
    ) {
      return json({ code: "ONBOARDING_NOT_CONFIGURED" }, 503);
    }
    const authRequest = async (
      path: string,
      body: object,
      method = "POST",
      sending = false,
    ) => {
      let response: Response;
      try {
        response = await fetch(`${url}/auth/v1/${path}`, {
          method,
          headers: {
            apikey: key,
            Authorization: `Bearer ${key}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(25000),
        });
      } catch {
        throw new SafeFailure(
          sending ? "DELIVERY_UNKNOWN" : "AUTH_UNAVAILABLE",
          503,
        );
      }
      if (!response.ok) {
        const data = await response.json().catch(() => ({})) as {
          code?: string | number;
          error_code?: string;
        };
        const nativeCode = data.error_code ?? data.code;
        throw new SafeFailure(
          nativeCode === "weak_password"
            ? "WEAK_PASSWORD"
            : nativeCode === "email_exists" ||
                nativeCode === "user_already_exists"
            ? "ONBOARDING_EMAIL_IN_USE"
            : sending
            ? "SMTP_FAILED"
            : "AUTH_REJECTED",
          response.status >= 500 ? 503 : 409,
        );
      }
    };
    return json(
      await execute(payload, {
        command,
        secret: Deno.env.get("PLATFORM_ONBOARDING_CONTEXT_SECRET") ?? key,
        callback,
        createAccount: (op, password) =>
          authRequest("admin/users", {
            id: op.intended_user_id,
            email: op.email,
            ...(password ? { password } : {}),
            email_confirm: op.mode === "direct",
            app_metadata: { onboarding_operation_id: op.id },
            user_metadata: {
              full_name: op.name,
              account_onboarding: op.mode === "invitation" ? "v1" : "direct",
            },
          }),
        setInitialPassword: (op, password) =>
          authRequest(`admin/users/${op.intended_user_id}`, {
            password,
            app_metadata: {
              onboarding_operation_id: op.id,
              onboarding_password_set: true,
            },
            user_metadata: { account_onboarding: "completed" },
          }, "PUT"),
        send: (op, redirect, continuation) =>
          Deno.env.get("PLATFORM_ONBOARDING_MAIL_ENABLED") !== "true"
            ? Promise.reject(new SafeFailure("SMTP_FAILED", 503))
            : authRequest(
              `${continuation ? "otp" : "invite"}?redirect_to=${
                encodeURIComponent(redirect)
              }`,
              continuation ? { email: op.email, create_user: false } : {
                email: op.email,
                data: { full_name: op.name, account_onboarding: "v1" },
              },
              "POST",
              true,
            ),
      }),
    );
  } catch (error) {
    // Do not log Auth errors: upstream details may contain email/token/password.
    if (error instanceof SafeFailure) {
      return json({ code: error.code }, error.status);
    }
    if (error instanceof SyntaxError) {
      return json({ code: "ONBOARDING_INVALID_REQUEST" }, 400);
    }
    return json({ code: "ONBOARDING_UNAVAILABLE" }, 503);
  }
});
