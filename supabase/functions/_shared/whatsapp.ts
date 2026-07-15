import type { SupabaseClient } from "@supabase/supabase-js";
import type { Json } from "./db_types.ts";
import type { Database } from "./types/database_types.ts";
import type {
  EndpointMessage,
  EndpointMessageResponse,
} from "./types/whatsapp_endpoint_types.ts";
import type {
  EndpointStatus,
  EndpointStatusResponse,
} from "./types/status_types.ts";

export const WHATSAPP_API_VERSION = "v24.0";

const RETRYABLE_META_CODES = new Set([
  1,
  2,
  4,
  80007,
  130429,
  131000,
  131016,
  131048,
  131056,
  131057,
  131064,
  133004,
]);

export class WhatsAppError extends Error {
  constructor(message: string, cause?: unknown) {
    super(message, { cause });
    this.name = "WhatsAppError";
  }
}

export type WhatsAppErrorDetails = {
  errorDetail: Json;
  errorMessage: string;
  isRetryable: boolean;
  metaCode?: number;
};

export function getWhatsAppErrorDetails(error: unknown): WhatsAppErrorDetails {
  const errorMessage = error instanceof Error ? error.message : String(error);
  const cause = error instanceof WhatsAppError
    ? error.cause as { error?: { code?: number }; status?: number } | undefined
    : undefined;
  const metaCode = cause?.error?.code;
  const httpStatus = cause?.status;
  const isTransientHttpFailure = httpStatus === 429 ||
    (httpStatus !== undefined && httpStatus >= 500);

  return {
    errorDetail: error instanceof WhatsAppError && error.cause !== undefined
      ? error.cause as Json
      : errorMessage,
    errorMessage,
    isRetryable: error instanceof TypeError || isTransientHttpFailure ||
      (metaCode !== undefined && RETRYABLE_META_CODES.has(metaCode)),
    metaCode,
  };
}

export function isWhatsAppBsuid(address: string): boolean {
  return /^[A-Z]{2}\.[A-Za-z0-9.]+$/.test(address);
}

export async function resolveWhatsAppRecipient({
  client,
  organizationId,
  contactAddress,
}: {
  client: SupabaseClient<Database>;
  organizationId: string;
  contactAddress: string;
}): Promise<{ to?: string; recipient?: string }> {
  if (!isWhatsAppBsuid(contactAddress)) {
    return { to: contactAddress };
  }

  const { data: contact } = await client
    .from("contacts_addresses")
    .select("phone_number:extra->>phone_number")
    .eq("organization_id", organizationId)
    .eq("address", contactAddress)
    .maybeSingle()
    .throwOnError();

  return {
    to: contact?.phone_number || undefined,
    recipient: contactAddress,
  };
}

export async function postPayloadToWhatsAppEndpoint(params: {
  payload: EndpointMessage;
  phoneNumberId: string;
  accessToken: string;
}): Promise<EndpointMessageResponse>;
export async function postPayloadToWhatsAppEndpoint(params: {
  payload: EndpointStatus;
  phoneNumberId: string;
  accessToken: string;
}): Promise<EndpointStatusResponse>;
export async function postPayloadToWhatsAppEndpoint({
  payload,
  phoneNumberId,
  accessToken,
}: {
  payload: EndpointMessage | EndpointStatus;
  phoneNumberId: string;
  accessToken: string;
}): Promise<EndpointMessageResponse | EndpointStatusResponse> {
  const response = await fetch(
    `https://graph.facebook.com/${WHATSAPP_API_VERSION}/${phoneNumberId}/messages`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    },
  );

  if (!response.ok) {
    const responseBody = await response.json().catch(() => ({}));
    throw new WhatsAppError(
      "Could not post payload to WhatsApp servers",
      typeof responseBody === "object" && responseBody !== null
        ? { ...responseBody, status: response.status }
        : { body: responseBody, status: response.status },
    );
  }

  return await response.json();
}
