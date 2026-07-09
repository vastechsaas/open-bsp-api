import type { SupabaseClient } from "@supabase/supabase-js";
import { HTTPException } from "jsr:@hono/hono/http-exception";
import type { ContentfulStatusCode } from "jsr:@hono/hono/utils/http-status";
import type { Database, OrganizationAddressRow } from "../_shared/supabase.ts";
import type { WhatsAppOrganizationAddressExtra } from "../_shared/types/extra_types.ts";

const API_VERSION = "v24.0";
const MAX_PROFILE_PHOTO_SIZE = 1024 * 1024;
const PROFILE_PHOTO_TYPES = new Set(["image/jpeg", "image/png"]);
const PROFILE_VERTICALS = new Set([
  "MATRIMONY_SERVICE",
  "AUTO",
  "BEAUTY",
  "APPAREL",
  "EDU",
  "ENTERTAIN",
  "EVENT_PLAN",
  "FINANCE",
  "GROCERY",
  "GOVT",
  "HOTEL",
  "HEALTH",
  "NONPROFIT",
  "PROF_SERVICES",
  "RETAIL",
  "TRAVEL",
  "RESTAURANT",
  "OTHER",
]);

type ProfileUpdate = {
  about: string;
  address: string;
  description: string;
  email: string;
  websites: string[];
  vertical: string;
};

type MetaBusinessProfile = ProfileUpdate & {
  profile_picture_url?: string;
};

type MetaPhoneNumber = {
  display_phone_number?: string;
  messaging_limit_tier?: string;
  quality_rating?: string;
  status?: string;
  verified_name?: string;
};

function normalizePhoneNumber(value: string) {
  return value.replace(/\D/g, "");
}

async function metaRequest<T>(
  url: string,
  accessToken: string,
  init?: RequestInit,
): Promise<T> {
  const response = await fetch(url, {
    ...init,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      ...init?.headers,
    },
  });

  if (!response.ok) {
    throw new HTTPException(response.status as ContentfulStatusCode, {
      message: "Meta Graph API request failed",
      cause: await response.json().catch(() => ({})),
    });
  }

  return await response.json();
}

async function getIntegration(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
): Promise<{
  row: OrganizationAddressRow;
  extra: WhatsAppOrganizationAddressExtra;
  accessToken: string;
}> {
  const { data, error } = await client
    .from("organizations_addresses")
    .select()
    .eq("organization_id", organizationId)
    .eq("address", organizationAddress)
    .maybeSingle();

  if (error) {
    throw new HTTPException(500, {
      message: "Could not load WhatsApp integration",
      cause: error,
    });
  }

  if (!data) {
    throw new HTTPException(404, {
      message: "WhatsApp integration not found",
    });
  }

  if (data.service !== "whatsapp") {
    throw new HTTPException(400, {
      message: "The selected integration is not a WhatsApp account",
    });
  }

  const extra = (data.extra as WhatsAppOrganizationAddressExtra | null) || {};

  if (!extra.access_token) {
    throw new HTTPException(409, {
      message: "The WhatsApp integration has no access token",
    });
  }

  return { row: data, extra, accessToken: extra.access_token };
}

async function fetchMetaProfile(
  phoneNumberId: string,
  accessToken: string,
) {
  const phoneUrl = new URL(
    `https://graph.facebook.com/${API_VERSION}/${phoneNumberId}`,
  );
  phoneUrl.searchParams.set(
    "fields",
    [
      "display_phone_number",
      "messaging_limit_tier",
      "quality_rating",
      "status",
      "verified_name",
    ].join(","),
  );

  const profileUrl = new URL(
    `https://graph.facebook.com/${API_VERSION}/${phoneNumberId}/whatsapp_business_profile`,
  );
  profileUrl.searchParams.set(
    "fields",
    [
      "about",
      "address",
      "description",
      "email",
      "profile_picture_url",
      "websites",
      "vertical",
    ].join(","),
  );

  const [phone, profileResponse] = await Promise.all([
    metaRequest<MetaPhoneNumber>(phoneUrl.toString(), accessToken),
    metaRequest<{ data?: MetaBusinessProfile[] }>(
      profileUrl.toString(),
      accessToken,
    ),
  ]);

  return {
    phone,
    profile: profileResponse.data?.[0] || {
      about: "",
      address: "",
      description: "",
      email: "",
      websites: [],
      vertical: "",
    },
  };
}

async function markDisconnected(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
) {
  await client
    .from("organizations_addresses")
    .update({ status: "disconnected" })
    .eq("organization_id", organizationId)
    .eq("address", organizationAddress);
}

function isAuthenticationError(error: unknown) {
  if (!(error instanceof HTTPException)) return false;
  if (error.status === 401) return true;

  const cause = error.cause as
    | { error?: { code?: number; type?: string } }
    | undefined;
  return (
    cause?.error?.code === 190 ||
    cause?.error?.type === "OAuthException"
  );
}

export async function syncWhatsAppProfile(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
) {
  const { extra, accessToken } = await getIntegration(
    client,
    organizationId,
    organizationAddress,
  );

  let meta;
  try {
    meta = await fetchMetaProfile(organizationAddress, accessToken);
  } catch (error) {
    if (isAuthenticationError(error)) {
      await markDisconnected(client, organizationId, organizationAddress);
    }
    throw error;
  }

  const { data, error } = await client
    .from("organizations_addresses")
    .update({
      status: "connected",
      extra: {
        ...extra,
        phone_number: meta.phone.display_phone_number
          ? normalizePhoneNumber(meta.phone.display_phone_number)
          : extra.phone_number,
        verified_name: meta.phone.verified_name || extra.verified_name,
        quality_rating: meta.phone.quality_rating,
        phone_number_status: meta.phone.status,
        messaging_limit_tier: meta.phone.messaging_limit_tier,
        profile_synced_at: new Date().toISOString(),
        business_profile: meta.profile,
      },
    })
    .eq("organization_id", organizationId)
    .eq("address", organizationAddress)
    .select()
    .single();

  if (error) {
    throw new HTTPException(500, {
      message: "Could not cache WhatsApp business profile",
      cause: error,
    });
  }

  return data;
}

function requiredString(form: FormData, name: string) {
  const value = form.get(name);
  if (typeof value !== "string") {
    throw new HTTPException(400, {
      message: `Missing '${name}' form field`,
    });
  }
  return value.trim();
}

function optionalString(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function validateProfile(form: FormData): ProfileUpdate {
  const vertical = requiredString(form, "vertical");
  const description = optionalString(form, "description");
  const address = optionalString(form, "address");
  const about = optionalString(form, "about");
  const email = optionalString(form, "email");
  const websitesValue = optionalString(form, "websites") || "[]";

  if (!PROFILE_VERTICALS.has(vertical)) {
    throw new HTTPException(400, {
      message: "Unsupported WhatsApp business category",
    });
  }
  if (description.length > 256 || address.length > 256) {
    throw new HTTPException(400, {
      message: "Description and address must not exceed 256 characters",
    });
  }
  if (about.length > 139) {
    throw new HTTPException(400, {
      message: "About must not exceed 139 characters",
    });
  }
  if (
    email &&
    (email.length > 128 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
  ) {
    throw new HTTPException(400, {
      message: "Email must be a valid address with at most 128 characters",
    });
  }

  let rawWebsites: unknown;
  try {
    rawWebsites = JSON.parse(websitesValue);
  } catch {
    throw new HTTPException(400, { message: "Websites must be a JSON array" });
  }
  if (!Array.isArray(rawWebsites) || rawWebsites.length > 2) {
    throw new HTTPException(400, {
      message: "WhatsApp profiles support at most two websites",
    });
  }

  const websites = rawWebsites.map((website) => {
    if (typeof website !== "string") {
      throw new HTTPException(400, {
        message: "Each website must be a URL string",
      });
    }
    const normalized = /^https?:\/\//i.test(website)
      ? website
      : `https://${website}`;
    let parsed: URL;
    try {
      parsed = new URL(normalized);
    } catch {
      throw new HTTPException(400, {
        message: `Invalid website URL: ${website}`,
      });
    }
    if (!["http:", "https:"].includes(parsed.protocol)) {
      throw new HTTPException(400, {
        message: `Invalid website URL: ${website}`,
      });
    }
    return parsed.toString();
  });

  return { about, address, description, email, websites, vertical };
}

function validatePhoto(form: FormData) {
  const value = form.get("file");
  if (!(value instanceof File) || value.size === 0) return undefined;
  if (value.size > MAX_PROFILE_PHOTO_SIZE) {
    throw new HTTPException(400, {
      message: "Profile photo must be 1 MB or smaller",
    });
  }
  if (!PROFILE_PHOTO_TYPES.has(value.type)) {
    throw new HTTPException(400, {
      message: "Profile photo must be a JPEG or PNG image",
    });
  }
  return value;
}

function resolveApplicationId(extra: WhatsAppOrganizationAddressExtra) {
  if (extra.application_id) return extra.application_id;

  const applicationIds = (Deno.env.get("META_APP_ID") || "")
    .split("|")
    .filter(Boolean);
  if (applicationIds.length === 1) return applicationIds[0];

  throw new HTTPException(409, {
    message:
      "Cannot identify the Meta application for this legacy integration. Reconnect the account before uploading a profile photo.",
  });
}

async function updateMetaProfile(
  phoneNumberId: string,
  accessToken: string,
  profile: ProfileUpdate,
) {
  await metaRequest(
    `https://graph.facebook.com/${API_VERSION}/${phoneNumberId}/whatsapp_business_profile`,
    accessToken,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        ...profile,
      }),
    },
  );
}

async function updateMetaProfilePhoto(
  phoneNumberId: string,
  accessToken: string,
  applicationId: string,
  file: File,
) {
  const sessionUrl = new URL(
    `https://graph.facebook.com/${API_VERSION}/${applicationId}/uploads`,
  );
  sessionUrl.searchParams.set("file_name", file.name || "profile-picture");
  sessionUrl.searchParams.set("file_length", String(file.size));
  sessionUrl.searchParams.set("file_type", file.type);

  const session = await metaRequest<{ id: string }>(
    sessionUrl.toString(),
    accessToken,
    { method: "POST" },
  );

  const uploadResponse = await fetch(
    `https://graph.facebook.com/${API_VERSION}/${session.id}`,
    {
      method: "POST",
      headers: {
        Authorization: `OAuth ${accessToken}`,
        file_offset: "0",
        "Content-Type": "application/octet-stream",
      },
      body: await file.arrayBuffer(),
    },
  );
  if (!uploadResponse.ok) {
    throw new HTTPException(uploadResponse.status as ContentfulStatusCode, {
      message: "Could not upload WhatsApp profile photo",
      cause: await uploadResponse.json().catch(() => ({})),
    });
  }
  const upload = await uploadResponse.json() as { h: string };

  await metaRequest(
    `https://graph.facebook.com/${API_VERSION}/${phoneNumberId}/whatsapp_business_profile`,
    accessToken,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        profile_picture_handle: upload.h,
      }),
    },
  );
}

export async function updateWhatsAppProfile(
  client: SupabaseClient<Database>,
  form: FormData,
) {
  const organizationId = requiredString(form, "organization_id");
  const organizationAddress = requiredString(form, "organization_address");
  const profile = validateProfile(form);
  const photo = validatePhoto(form);
  const { extra, accessToken } = await getIntegration(
    client,
    organizationId,
    organizationAddress,
  );
  const applicationId = photo ? resolveApplicationId(extra) : undefined;

  try {
    await updateMetaProfile(organizationAddress, accessToken, profile);
    if (photo && applicationId) {
      await updateMetaProfilePhoto(
        organizationAddress,
        accessToken,
        applicationId,
        photo,
      );
    }
  } catch (error) {
    if (isAuthenticationError(error)) {
      await markDisconnected(client, organizationId, organizationAddress);
    }
    throw error;
  }

  return await syncWhatsAppProfile(
    client,
    organizationId,
    organizationAddress,
  );
}
