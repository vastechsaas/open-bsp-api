import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { z } from "zod";
import * as log from "../_shared/logger.ts";
import {
  createApiClient,
  createUnsecureClient,
  type Json,
} from "../_shared/supabase.ts";
import {
  parseChatbotReplyPayload,
  resolveExternalReplyId,
  toOutgoingMessageContent,
  UnsupportedMessageTypeError,
} from "./payload.ts";

type DatabaseError = {
  code?: string;
  message?: string;
  details?: string;
  hint?: string;
};

type RecordReplyResult = {
  outcome: "stored" | "merged" | "duplicate";
  message_id: string;
};

function jsonResponse(
  body: Record<string, unknown>,
  status: number,
): Response {
  return Response.json(body, { status });
}

function databaseErrorResponse(error: DatabaseError): Response {
  if (error.code === "P0002") {
    return jsonResponse({ message: error.message ?? "Not found" }, 404);
  }

  if (error.code === "23505" || error.code === "23514") {
    return jsonResponse({ message: error.message ?? "Conflict" }, 409);
  }

  if (error.code === "22023") {
    return jsonResponse({ message: error.message ?? "Invalid request" }, 400);
  }

  log.error("Failed to record external chatbot reply", error);
  return jsonResponse({ message: "Internal Server Error" }, 500);
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return jsonResponse({ message: "Method Not Allowed" }, 405);
  }

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ") || authorization.length <= 7) {
    return jsonResponse({ message: "Missing authorization token" }, 401);
  }

  let apiKey;
  try {
    const apiClient = createApiClient(request);
    const { data, error } = await apiClient
      .from("api_keys")
      .select("organization_id")
      .eq("key", authorization.slice(7))
      .maybeSingle();

    if (error || !data) {
      log.warn("Invalid chatbot reply API key", error ?? undefined);
      return jsonResponse({ message: "Invalid API key" }, 401);
    }

    apiKey = data;
  } catch (error) {
    log.warn("Failed to authenticate chatbot reply request", error as Error);
    return jsonResponse({ message: "Invalid API key" }, 401);
  }

  let requestBody: unknown;
  try {
    requestBody = await request.json();
  } catch {
    return jsonResponse({ message: "Request body must be valid JSON" }, 400);
  }

  let payload;
  try {
    payload = parseChatbotReplyPayload(requestBody);
  } catch (error) {
    if (error instanceof UnsupportedMessageTypeError) {
      return jsonResponse({
        message: error.message,
        supported_types: ["text", "interactive"],
      }, 422);
    }

    if (error instanceof z.ZodError) {
      return jsonResponse({
        message: "Invalid request payload",
        issues: error.issues,
      }, 400);
    }

    throw error;
  }

  const serviceClient = createUnsecureClient();
  const externalId = resolveExternalReplyId(payload.wamid);

  const { data: address, error: addressError } = await serviceClient
    .from("organizations_addresses")
    .select("address")
    .eq("organization_id", apiKey.organization_id)
    .eq("address", payload.phone_number_id)
    .eq("service", "whatsapp")
    .eq("status", "connected")
    .maybeSingle();

  if (addressError) {
    log.error("Failed to resolve chatbot WhatsApp address", addressError);
    return jsonResponse({ message: "Internal Server Error" }, 500);
  }

  if (!address) {
    return jsonResponse({
      message: "Connected WhatsApp phone number not found",
    }, 404);
  }

  const { data: agentId, error: agentError } = await serviceClient.rpc(
    "ensure_external_chatbot_agent",
    {
      p_organization_id: apiKey.organization_id,
      p_integration_key: payload.chatbot.key,
      p_name: payload.chatbot.name,
    },
  );

  if (agentError) {
    return databaseErrorResponse(agentError);
  }

  const content = toOutgoingMessageContent(payload);
  const { data: recordedRows, error: recordError } = await serviceClient.rpc(
    "record_external_chatbot_reply",
    {
      p_organization_id: apiKey.organization_id,
      p_agent_id: agentId,
      p_phone_number_id: payload.phone_number_id,
      p_recipient: payload.recipient,
      p_wamid: externalId,
      p_sent_at: payload.sent_at,
      p_content: content as unknown as Json,
    },
  );

  if (recordError) {
    return databaseErrorResponse(recordError);
  }

  const result = recordedRows?.[0] as RecordReplyResult | undefined;
  if (!result) {
    log.error("Reply recording RPC returned no result", {
      organization_id: apiKey.organization_id,
      wamid: payload.wamid,
    });
    return jsonResponse({ message: "Internal Server Error" }, 500);
  }

  log.info("Recorded external chatbot reply", {
    organization_id: apiKey.organization_id,
    message_id: result.message_id,
    external_id: externalId,
    wamid_provided: payload.wamid != null,
    outcome: result.outcome,
  });

  return jsonResponse({
    outcome: result.outcome,
    message_id: result.message_id,
    external_id: externalId,
  }, result.outcome === "stored" ? 201 : 200);
});
