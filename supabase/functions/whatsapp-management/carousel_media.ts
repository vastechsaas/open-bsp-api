import type { SupabaseClient } from "@supabase/supabase-js";
import { HTTPException } from "jsr:@hono/hono/http-exception";
import type { Database } from "../_shared/supabase.ts";
import type { CarouselMediaAsset } from "../_shared/types/whatsapp_template_types.ts";
import { parseCarouselAssets } from "../_shared/carousel.ts";
import {
  createSignedUrl,
  downloadFromStorage,
  uploadToStorage,
} from "../_shared/media.ts";
import { validateTemplateMediaSample } from "../_shared/meta_media.ts";

/** One bounded upload, authorized against an existing mutable tenant draft. */
export async function uploadCarouselImage(
  client: SupabaseClient<Database>,
  organizationId: string,
  resource: "template" | "campaign",
  draftId: string,
  cardId: string,
  file: File,
) {
  validateTemplateMediaSample(file, "IMAGE");
  if (resource === "template") {
    const { data: organizations, error } = await client.rpc(
      "get_authorized_orgs_by_roles",
      { roles: ["owner", "admin"] },
    );
    if (error || !organizations?.includes(organizationId)) {
      throw new HTTPException(403, {
        message: "Template management requires Owner or Admin access",
      });
    }
  }
  await validateImageBytes(file);
  const { data, error } = await client.from(
    resource === "template" ? "message_templates" : "campaigns",
  )
    .select("id").eq("organization_id", organizationId).eq("id", draftId).eq(
      "status",
      "draft",
    ).maybeSingle();
  if (error || !data) {
    throw new HTTPException(404, {
      message: "An accessible draft is required for image uploads",
    });
  }
  // Validate identity before writing storage; storage retains its existing tenant/quota policies.
  parseCarouselAssets([{
    card_id: cardId,
    storage_uri:
      `internal://media/organizations/${organizationId}/attachments/${
        "a".repeat(43)
      }`,
    file_name: file.name,
    mime_type: file.type,
    size: file.size,
  }], organizationId);
  const uri = await uploadToStorage(client, organizationId, file, file.name);
  const asset = parseCarouselAssets([{
    card_id: cardId,
    storage_uri: uri,
    file_name: file.name,
    mime_type: file.type,
    size: file.size,
  }], organizationId)[0];
  return { asset, preview_url: await createSignedUrl(client, uri) };
}

export async function loadCarouselImages(
  client: SupabaseClient<Database>,
  organizationId: string,
  assets: unknown,
  cardCount: number,
): Promise<{ asset: CarouselMediaAsset; file: File }[]> {
  const references = parseCarouselAssets(assets, organizationId);
  if (references.length !== cardCount) {
    throw new HTTPException(409, {
      message: "Upload an image for every carousel card before continuing",
    });
  }
  const files = [];
  for (const [index, asset] of references.entries()) {
    try {
      const blob = await downloadFromStorage(client, asset.storage_uri);
      const file = new File([blob], asset.file_name, { type: blob.type });
      validateTemplateMediaSample(file, "IMAGE");
      await validateImageBytes(file);
      if (file.size !== asset.size || file.type !== asset.mime_type) {
        throw new Error("Image metadata mismatch");
      }
      files.push({ asset, file });
    } catch {
      throw new HTTPException(409, {
        message: `Card ${
          index + 1
        }: retained image is unavailable. Upload it again.`,
      });
    }
  }
  return files;
}

async function validateImageBytes(file: File) {
  const bytes = new Uint8Array(await file.slice(0, 8).arrayBuffer());
  const valid = file.type === "image/png"
    ? [137, 80, 78, 71, 13, 10, 26, 10].every((value, index) =>
      bytes[index] === value
    )
    : bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
  if (!valid) {
    throw new HTTPException(400, {
      message: "Image content does not match its JPEG or PNG file type",
    });
  }
}
