import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { z } from "zod";
import * as log from "../_shared/logger.ts";
import {
  createClient,
  createUnsecureClient,
  type Json,
  type WhatsAppOrganizationAddressExtra,
} from "../_shared/supabase.ts";
import { syncWhatsAppProfile } from "../whatsapp-management/profile.ts";
import { syncTemplates } from "../whatsapp-management/templates.ts";
import {
  ACTION_AUDIT_TYPES,
  type PlatformWhatsAppHealthPayload,
  platformWhatsAppHealthPayloadSchema,
} from "./payload.ts";

const API_VERSION = "v24.0";
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

type SafeResult = {
  success: boolean;
  action: PlatformWhatsAppHealthPayload["action"];
  checked_at: string;
  message: string;
  synced?: number;
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function sanitizeFailure(error: unknown) {
  const value = error as {
    status?: number;
    message?: string;
    cause?: { error?: { code?: number; type?: string; message?: string } };
  };
  const meta = value.cause?.error;
  const authentication = value.status === 401 || meta?.code === 190 ||
    meta?.type === "OAuthException";
  return {
    code: authentication ? "META_AUTHENTICATION_FAILED" : "META_REQUEST_FAILED",
    message: authentication
      ? "The WhatsApp access token is invalid or expired."
      : "Meta could not complete the requested operation.",
    tokenStatus: authentication ? "invalid" : "error",
  };
}

async function fetchMetaJson(url: string, accessToken: string) {
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw { status: response.status, cause: body };
  }
  return body as Record<string, unknown>;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (request.method !== "POST") {
    return jsonResponse({ message: "Method not allowed" }, 405);
  }

  try {
    const client = createClient(request);
    const service = createUnsecureClient();
    const { data: { user }, error: userError } = await client.auth.getUser();
    if (userError || !user) {
      return jsonResponse({ message: "Invalid authentication" }, 401);
    }

    const { data: isPlatformAdmin } = await client.rpc("is_platform_admin");
    if (!isPlatformAdmin) {
      return jsonResponse(
        { message: "Platform administrator access required" },
        403,
      );
    }

    const payload = platformWhatsAppHealthPayloadSchema.parse(
      await request.json(),
    );
    const auditType = ACTION_AUDIT_TYPES[payload.action];
    const { data: previous, error: previousError } = await client.rpc(
      "get_platform_whatsapp_action_result",
      {
        p_organization_id: payload.organization_id,
        p_phone_number_id: payload.phone_number_id,
        p_action_type: auditType,
        p_request_id: payload.request_id,
      },
    );
    if (previousError) throw previousError;
    if (previous) {
      const previousSucceeded = typeof previous === "object" &&
        !Array.isArray(previous) && previous.success === true;
      return jsonResponse(previous, previousSucceeded ? 200 : 502);
    }

    const { data: account, error: accountError } = await service
      .from("organizations_addresses")
      .select("organization_id,address,service,status,extra")
      .eq("organization_id", payload.organization_id)
      .eq("address", payload.phone_number_id)
      .eq("service", "whatsapp")
      .maybeSingle();
    if (accountError) throw accountError;
    if (!account) {
      return jsonResponse({ message: "WhatsApp integration not found" }, 404);
    }

    const checkedAt = new Date().toISOString();
    let result: SafeResult;
    try {
      if (payload.action === "test_connection") {
        const extra = (account.extra || {}) as WhatsAppOrganizationAddressExtra;
        if (!extra.access_token || !extra.waba_id) {
          throw { status: 401 };
        }
        const phoneUrl = new URL(
          `https://graph.facebook.com/${API_VERSION}/${payload.phone_number_id}`,
        );
        phoneUrl.searchParams.set(
          "fields",
          "display_phone_number,messaging_limit_tier,quality_rating,status,verified_name",
        );
        const subscriptionUrl = new URL(
          `https://graph.facebook.com/${API_VERSION}/${extra.waba_id}/subscribed_apps`,
        );
        const [phone, subscriptions] = await Promise.all([
          fetchMetaJson(phoneUrl.toString(), extra.access_token),
          fetchMetaJson(subscriptionUrl.toString(), extra.access_token),
        ]);
        const subscribed = Array.isArray(subscriptions.data) &&
          subscriptions.data.length > 0;
        const phoneStatus = String(phone.status || "");
        const operational = !phoneStatus ||
          ["CONNECTED", "APPROVED", "VERIFIED"].includes(
            phoneStatus.toUpperCase(),
          );
        await service.from("whatsapp_integration_health").upsert({
          organization_id: payload.organization_id,
          phone_number_id: payload.phone_number_id,
          last_check_attempted_at: checkedAt,
          last_check_succeeded_at: checkedAt,
          token_status: "valid",
          token_validated_at: checkedAt,
          webhook_subscription_status: subscribed
            ? "subscribed"
            : "unsubscribed",
          webhook_validated_at: checkedAt,
          failure_code: operational && subscribed
            ? null
            : "INTEGRATION_WARNING",
          failure_message: operational && subscribed
            ? null
            : "The account requires attention.",
        }, { onConflict: "organization_id,phone_number_id" }).throwOnError();
        result = {
          success: true,
          action: payload.action,
          checked_at: checkedAt,
          message: subscribed && operational
            ? "WhatsApp connection is healthy."
            : "WhatsApp connection was checked and requires attention.",
        };
      } else if (payload.action === "refresh_account") {
        await syncWhatsAppProfile(
          service,
          payload.organization_id,
          payload.phone_number_id,
        );
        result = {
          success: true,
          action: payload.action,
          checked_at: checkedAt,
          message: "Account information refreshed.",
        };
      } else {
        const sync = await syncTemplates(
          service,
          payload.organization_id,
          payload.phone_number_id,
        );
        result = {
          success: true,
          action: payload.action,
          checked_at: checkedAt,
          message: "Templates synchronized.",
          synced: sync.synced,
        };
      }
    } catch (error) {
      const failure = sanitizeFailure(error);
      if (payload.action === "test_connection") {
        await service.from("whatsapp_integration_health").upsert({
          organization_id: payload.organization_id,
          phone_number_id: payload.phone_number_id,
          last_check_attempted_at: checkedAt,
          token_status: failure.tokenStatus,
          token_validated_at: checkedAt,
          webhook_subscription_status: "error",
          webhook_validated_at: checkedAt,
          failure_code: failure.code,
          failure_message: failure.message,
        }, { onConflict: "organization_id,phone_number_id" }).throwOnError();
      }
      result = {
        success: false,
        action: payload.action,
        checked_at: checkedAt,
        message: failure.message,
      };
    }

    const { error: auditError } = await client.rpc(
      "record_platform_whatsapp_action",
      {
        p_organization_id: payload.organization_id,
        p_phone_number_id: payload.phone_number_id,
        p_action_type: auditType,
        p_request_id: payload.request_id,
        p_after_state: result as unknown as Json,
      },
    );
    if (auditError) throw auditError;
    return jsonResponse(result, result.success ? 200 : 502);
  } catch (error) {
    if (error instanceof z.ZodError || error instanceof SyntaxError) {
      return jsonResponse({ message: "Invalid WABA health request" }, 400);
    }
    const databaseError = error as { code?: string };
    if (databaseError.code === "42501") {
      return jsonResponse(
        { message: "Platform administrator access required" },
        403,
      );
    }
    if (databaseError.code === "P0002") {
      return jsonResponse({ message: "WhatsApp integration not found" }, 404);
    }
    log.error("Platform WhatsApp health action failed", error);
    return jsonResponse({ message: "WABA health action failed" }, 500);
  }
});
