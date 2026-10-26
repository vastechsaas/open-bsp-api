import type { createUnsecureClient } from "../_shared/supabase.ts";
import type { Json } from "../_shared/db_types.ts";
import {
  type Dependencies,
  digest,
  type Operation,
  type Payload,
  SafeFailure,
} from "./core.ts";

/** Shared Auth adapter for Team members and organization provisioning. */
export function accountSetupDependencies(
  service: ReturnType<typeof createUnsecureClient>,
  actor: string,
  recipient?: Extract<Payload, { action: "complete" }>,
): Dependencies {
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const callback = Deno.env.get("PLATFORM_ONBOARDING_CALLBACK_URL") ?? "";
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
      const code = data.error_code ?? data.code;
      throw new SafeFailure(
        code === "weak_password"
          ? "WEAK_PASSWORD"
          : code === "email_exists" || code === "user_already_exists"
          ? "ONBOARDING_EMAIL_IN_USE"
          : sending
          ? "SMTP_FAILED"
          : "AUTH_REJECTED",
        response.status >= 500 ? 503 : 409,
      );
    }
  };
  return {
    callback,
    secret: Deno.env.get("PLATFORM_ONBOARDING_CONTEXT_SECRET") ?? key,
    command: async (command, input) => {
      const name = recipient && (command === "status" || command === "failed")
        ? `complete_${command}`
        : command;
      const { data, error } = await service.rpc("platform_onboarding_command", {
        p_actor: actor,
        p_command: name,
        p_payload: JSON.parse(JSON.stringify({
          ...input,
          ...(recipient
            ? { context_hash: await digest(recipient.context) }
            : {}),
        })) as Json,
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
    },
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
  };
}
export function assertAccountSetupConfigured(action: string) {
  if (
    !["preview", "status", "complete"].includes(action) &&
    ![
      "https://vistagalaxy.vastech.biz/onboard/set-password",
      "https://socialconnect.vastech.biz/onboard/set-password",
    ].includes(Deno.env.get("PLATFORM_ONBOARDING_CALLBACK_URL") ?? "")
  ) {
    throw new SafeFailure("ONBOARDING_NOT_CONFIGURED", 503);
  }
}
