import { HTTPException } from "jsr:@hono/hono/http-exception";
import type { ContentfulStatusCode } from "jsr:@hono/hono/utils/http-status";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../_shared/supabase.ts";
import { canonicalCarousel, imageCarousel } from "../_shared/carousel.ts";
import { parseTemplateDraftInput } from "../_shared/template_validation.ts";
import type { TemplateDraftInput } from "../_shared/types/whatsapp_template_types.ts";
import { loadCarouselImages } from "./carousel_media.ts";
import { WhatsAppError } from "../_shared/whatsapp.ts";
import {
  META_GRAPH_API_VERSION,
  validateTemplateMediaSample,
} from "../_shared/meta_media.ts";
import type { MediaHeaderFormat } from "../_shared/types/whatsapp_template_types.ts";
import type { WhatsAppOrganizationAddressExtra } from "../_shared/types/extra_types.ts";

const DEFAULT_ACCESS_TOKEN = Deno.env.get("META_SYSTEM_USER_ACCESS_TOKEN") ||
  "";

export type CampaignHeaderMedia = {
  format: MediaHeaderFormat;
  media_id: string;
  file_name: string;
  mime_type: string;
  size: number;
};

async function readMetaJson<T>(
  response: Response,
  message: string,
): Promise<T> {
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new HTTPException(response.status as ContentfulStatusCode, {
      message,
      cause: body,
    });
  }
  return body as T;
}

async function getCredentials(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
) {
  const { data, error } = await client.from("organizations_addresses")
    .select("extra")
    .eq("organization_id", organizationId)
    .eq("address", organizationAddress)
    .eq("service", "whatsapp")
    .eq("status", "connected")
    .maybeSingle();
  if (error || !data) {
    throw new HTTPException(403, {
      message: "The WhatsApp account is not connected or accessible",
      cause: error,
    });
  }
  const extra = (data.extra as WhatsAppOrganizationAddressExtra | null) || {};
  const accessToken = extra.access_token || DEFAULT_ACCESS_TOKEN;
  if (!accessToken) {
    throw new HTTPException(422, {
      message: "WhatsApp account credentials are not configured",
    });
  }
  return { accessToken };
}

export async function uploadCampaignMedia(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
  format: MediaHeaderFormat,
  file: File,
): Promise<CampaignHeaderMedia> {
  validateTemplateMediaSample(file, format);
  const { accessToken } = await getCredentials(
    client,
    organizationId,
    organizationAddress,
  );
  const form = new FormData();
  form.set("messaging_product", "whatsapp");
  form.set("file", file);
  const response = await fetch(
    `https://graph.facebook.com/${META_GRAPH_API_VERSION}/${organizationAddress}/media`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}` },
      body: form,
    },
  );
  const result = await readMetaJson<{ id?: string }>(
    response,
    "Could not upload campaign media to Meta",
  );
  if (!result.id) {
    throw new HTTPException(502, { message: "Meta did not return a media ID" });
  }
  return {
    format,
    media_id: result.id,
    file_name: file.name,
    mime_type: file.type,
    size: file.size,
  };
}

export async function getMetaMedia(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
  mediaId: string,
) {
  const { accessToken } = await getCredentials(
    client,
    organizationId,
    organizationAddress,
  );
  const url = new URL(
    `https://graph.facebook.com/${META_GRAPH_API_VERSION}/${mediaId}`,
  );
  url.searchParams.set("phone_number_id", organizationAddress);
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const metadata = await readMetaJson<
    { id: string; url: string; mime_type?: string; file_size?: number }
  >(
    response,
    "Campaign media is no longer available on Meta",
  );
  return { metadata, accessToken };
}

export async function proxyCampaignMedia(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
  mediaId: string,
): Promise<Response> {
  const { data: campaign, error } = await client.from("campaigns")
    .select("id")
    .eq("organization_id", organizationId)
    .eq("organization_address", organizationAddress)
    .contains("header_media", { media_id: mediaId })
    .maybeSingle();
  if (error || !campaign) {
    throw new HTTPException(404, { message: "Campaign media was not found" });
  }
  const { metadata, accessToken } = await getMetaMedia(
    client,
    organizationId,
    organizationAddress,
    mediaId,
  );
  const download = await fetch(metadata.url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!download.ok || !download.body) {
    throw new HTTPException(502, {
      message: "Could not download campaign media from Meta",
    });
  }
  return new Response(download.body, {
    headers: {
      "Content-Type": metadata.mime_type ||
        download.headers.get("Content-Type") || "application/octet-stream",
      "Cache-Control": "private, max-age=300",
    },
  });
}

export async function deleteCampaignMedia(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
  mediaId: string,
) {
  const { accessToken } = await getCredentials(
    client,
    organizationId,
    organizationAddress,
  );
  const url = new URL(
    `https://graph.facebook.com/${META_GRAPH_API_VERSION}/${mediaId}`,
  );
  url.searchParams.set("phone_number_id", organizationAddress);
  const response = await fetch(url, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  return await readMetaJson<Record<string, unknown>>(
    response,
    "Could not delete campaign media from Meta",
  );
}

export async function startCampaignWithMediaValidation(
  client: SupabaseClient<Database>,
  organizationId: string,
  campaignId: string,
) {
  const { data: campaign, error } = await client.from("campaigns")
    .select("organization_address, template, header_media, carousel_media")
    .eq("organization_id", organizationId)
    .eq("id", campaignId)
    .maybeSingle();
  if (error || !campaign) {
    throw new HTTPException(404, { message: "Campaign not found" });
  }

  const template = campaign.template as Record<string, unknown>;
  const components = Array.isArray(template.components)
    ? template.components
    : [];
  if (imageCarousel(template)) {
    const definition = parseTemplateDraftInput(
      canonicalCarousel(template as unknown as TemplateDraftInput),
      { requireComplete: true },
    );
    // Preflight is deliberately before queueing. Worker obtains fresh send handles from retained bytes.
    await loadCarouselImages(
      client,
      organizationId,
      campaign.carousel_media,
      imageCarousel(definition)!.cards.length,
    );
  }
  const mediaHeader = components.find((value) => {
    const component = value as Record<string, unknown>;
    return component.type === "HEADER" &&
      ["IMAGE", "VIDEO", "DOCUMENT"].includes(String(component.format));
  }) as Record<string, unknown> | undefined;
  if (mediaHeader) {
    const media = campaign.header_media as CampaignHeaderMedia | null;
    if (!media || media.format !== mediaHeader.format || !media.media_id) {
      throw new HTTPException(409, {
        message:
          "Upload media matching the template header before running this campaign",
      });
    }
    await getMetaMedia(
      client,
      organizationId,
      campaign.organization_address,
      media.media_id,
    );
  }
  const { data, error: startError } = await client.rpc("start_campaign", {
    p_organization_id: organizationId,
    p_campaign_id: campaignId,
  });
  if (startError) {
    throw new HTTPException(409, {
      message: startError.message,
      cause: startError,
    });
  }
  return { queued_count: data };
}

/** Cached per campaign batch by the caller; never trust client-supplied Meta media IDs. */
export async function prepareCampaignCarouselMedia(
  client: SupabaseClient<Database>,
  organizationId: string,
  organizationAddress: string,
  template: Json,
  media: Json,
): Promise<Json> {
  const carousel = imageCarousel(template as { components?: unknown });
  if (!carousel) return [];
  parseTemplateDraftInput(
    canonicalCarousel(template as unknown as TemplateDraftInput),
    { requireComplete: true },
  );
  const images = await loadCarouselImages(
    client,
    organizationId,
    media,
    carousel.cards.length,
  );
  const prepared = [];
  for (const [index, { asset, file }] of images.entries()) {
    let uploaded: CampaignHeaderMedia;
    try {
      uploaded = await uploadCampaignMedia(
        client,
        organizationId,
        organizationAddress,
        "IMAGE",
        file,
      );
    } catch (error) {
      if (error instanceof HTTPException) {
        throw new WhatsAppError(`Card ${index + 1}: image preparation failed`, {
          ...(error.cause && typeof error.cause === "object"
            ? error.cause
            : {}),
          status: error.status,
        });
      }
      throw error;
    }
    prepared.push({ ...asset, card_index: index, media_id: uploaded.media_id });
  }
  return prepared as unknown as Json;
}
