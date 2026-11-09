import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Json } from "../_shared/db_types.ts";
import type { Database } from "../_shared/supabase.ts";
import { mappedValue } from "../_shared/campaign_template.ts";
import { parseCarouselAssets } from "../_shared/carousel.ts";

export const campaignReplyRequest = z.object({
  organization_id: z.string().uuid(),
  conversation_id: z.string().uuid(),
  reply_ids: z.array(z.string().uuid()).min(1).max(50),
}).strict();

type Table<T extends keyof Database["public"]["Tables"]> =
  Database["public"]["Tables"][T]["Row"];
type Campaign = Pick<
  Table<"campaigns">,
  | "name"
  | "organization_address"
  | "template"
  | "template_variable_mapping"
  | "carousel_media"
>;
type Delivery = Pick<
  Table<"campaign_deliveries">,
  "contact_address" | "name" | "variables"
>;
type Part = { text?: string; links: { label: string; url: string }[] };
type Preview = {
  name: string;
  header?: string;
  body?: string;
  footer?: string;
  links: Part["links"];
  cards: (Part & { imagePath?: string })[];
};

function record(value: unknown): Record<string, Json | undefined> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, Json | undefined>
    : {};
}

function components(value: unknown) {
  return Array.isArray(value) ? value.map(record) : [];
}

export function sameCampaignRecipient(left: string | null, right: string) {
  return !!left && /^\+?\d+$/.test(left) && /^\+?\d+$/.test(right) &&
    left.replace(/^\+/, "") === right.replace(/^\+/, "");
}

export function campaignReplyPreview(
  campaign: Campaign,
  delivery: Delivery,
  organizationId: string,
): Preview {
  const mapping = record(campaign.template_variable_mapping);
  const values = {
    contactAddress: delivery.contact_address,
    contactName: delivery.name,
    variables: delivery.variables,
  };
  function resolve(value: Json | undefined, key: string) {
    if (typeof value !== "string") return undefined;
    try {
      return value.replace(/\{\{\s*(\d+)\s*\}\}/g, (_, index) => {
        const source = mapping[`${key}.${index}`];
        if (typeof source !== "string") throw new Error("Unmapped value");
        return mappedValue(source, values);
      });
    } catch {
      return undefined;
    }
  }
  function links(parts: ReturnType<typeof components>, prefix: string) {
    return components(parts.find((part) => part.type === "BUTTONS")?.buttons)
      .flatMap((button, index) => {
        if (
          button.type !== "URL" || typeof button.text !== "string" ||
          typeof button.url !== "string"
        ) return [];
        const url = resolve(button.url, `${prefix}button.${index}`);
        try {
          const parsed = new URL(url ?? "");
          const base = new URL(button.url);
          if (
            parsed.protocol === "https:" && parsed.origin === base.origin &&
            !parsed.username && !parsed.password
          ) {
            return [{ label: button.text, url: parsed.href }];
          }
        } catch { /* Invalid or unavailable website buttons are omitted. */ }
        return [];
      });
  }
  const parts = components(record(campaign.template).components);
  const carousel = parts.find((part) => part.type === "CAROUSEL");
  let images: ReturnType<typeof parseCarouselAssets> = [];
  try {
    images = parseCarouselAssets(campaign.carousel_media, organizationId);
  } catch { /* Legacy or missing media must not hide the text. */ }
  const cards = components(carousel?.cards).slice(0, 10).map((card, index) => {
    const parts = components(card.components);
    const image = images[index];
    return {
      text: resolve(
        parts.find((part) => part.type === "BODY")?.text,
        `carousel.${index}.body`,
      ),
      links: links(parts, `carousel.${index}.`),
      imagePath: image?.storage_uri.replace("internal://media/", ""),
    };
  });
  return {
    name: campaign.name,
    header: resolve(
      parts.find((part) => part.type === "HEADER")?.text,
      "header",
    ),
    body: resolve(parts.find((part) => part.type === "BODY")?.text, "body"),
    footer: resolve(
      parts.find((part) => part.type === "FOOTER")?.text,
      "footer",
    ),
    links: links(parts, ""),
    cards,
  };
}

export async function readCampaignReplyContext(
  user: SupabaseClient<Database>,
  service: SupabaseClient<Database>,
  input: z.infer<typeof campaignReplyRequest>,
) {
  const { organization_id, conversation_id, reply_ids } = input;
  // Only a visible, persisted inbound reply can unlock a campaign snapshot.
  // Neither a client-supplied WhatsApp ID nor campaign permissions can bypass chat RLS.
  const { data: conversation } = await user.from("conversations").select("id")
    .eq("organization_id", organization_id).eq("id", conversation_id)
    .eq("service", "whatsapp").maybeSingle().throwOnError();
  if (!conversation) return [];
  const { data: replies } = await user.from("messages")
    .select("id,contact_address,organization_address,content")
    .eq("organization_id", organization_id).eq(
      "conversation_id",
      conversation_id,
    )
    .eq("service", "whatsapp").eq("direction", "incoming").is(
      "group_address",
      null,
    )
    .in("id", reply_ids).throwOnError();
  const quoted = replies.flatMap((reply) => {
    const content = record(reply.content);
    const id = content.re_message_id;
    return typeof id === "string" && /^wamid\.[\w+=/-]{1,512}$/.test(id) &&
        content.kind !== "reaction"
      ? [{ ...reply, quotedId: id }]
      : [];
  });
  if (!quoted.length) return [];
  const { data: deliveries } = await service.from("campaign_deliveries")
    .select("campaign_id,external_id,contact_address,name,variables")
    .eq("organization_id", organization_id).eq("status", "accepted")
    .in("external_id", [...new Set(quoted.map((reply) => reply.quotedId))])
    .throwOnError();
  if (!deliveries.length) return [];
  const { data: campaigns } = await service.from("campaigns")
    .select(
      "id,name,organization_address,template,template_variable_mapping,carousel_media",
    )
    .eq("organization_id", organization_id)
    .in("id", [...new Set(deliveries.map((delivery) => delivery.campaign_id))])
    .throwOnError();
  const byExternal = new Map(deliveries.map((row) => [row.external_id, row]));
  const byCampaign = new Map(campaigns.map((row) => [row.id, row]));
  const previews = quoted.flatMap((reply) => {
    const delivery = byExternal.get(reply.quotedId);
    const campaign = delivery && byCampaign.get(delivery.campaign_id);
    if (
      !delivery || !campaign ||
      campaign.organization_address !== reply.organization_address ||
      !sameCampaignRecipient(reply.contact_address, delivery.contact_address)
    ) {
      return [];
    }
    return [{
      reply_id: reply.id,
      ...campaignReplyPreview(campaign, delivery, organization_id),
    }];
  });
  return await signCampaignPreviews(service, previews);
}

// Keep backend requests on the internal gateway, but never return that Docker
// hostname to browsers. Hosted projects without an override retain SDK URLs.
export function publicCampaignImageUrl(
  signedUrl: string | undefined,
  publicBase = Deno.env.get("SUPABASE_PUBLIC_URL"),
): string | undefined {
  if (!signedUrl || !publicBase) return signedUrl;
  try {
    const base = new URL(publicBase);
    const image = new URL(signedUrl);
    if (
      base.protocol !== "https:" || base.username || base.password ||
      base.pathname !== "/" || base.search || base.hash ||
      !["http:", "https:"].includes(image.protocol) ||
      !image.pathname.startsWith("/storage/v1/object/sign/media/")
    ) return undefined;
    image.protocol = base.protocol;
    image.host = base.host;
    image.port = base.port;
    image.username = "";
    image.password = "";
    image.hash = "";
    return image.href;
  } catch {
    // Misconfigured public URLs must not leak private hosts or hide chat text.
    return undefined;
  }
}

export async function signCampaignPreviews<T extends Preview>(
  service: SupabaseClient<Database>,
  previews: T[],
  publicBase = Deno.env.get("SUPABASE_PUBLIC_URL"),
) {
  const paths = [
    ...new Set(
      previews.flatMap(({ cards }) =>
        cards.flatMap(({ imagePath }) => imagePath ? [imagePath] : [])
      ),
    ),
  ];
  const signed = paths.length
    ? (await service.storage.from("media").createSignedUrls(paths, 900)).data
    : [];
  const urls = new Map(
    signed?.map(({ path, signedUrl }) => [
      path,
      publicCampaignImageUrl(signedUrl, publicBase),
    ]),
  );
  return previews.map((preview) => ({
    ...preview,
    cards: preview.cards.map(({ imagePath, ...card }) => ({
      ...card,
      ...(imagePath && urls.get(imagePath)
        ? { image_url: urls.get(imagePath) }
        : {}),
    })),
  }));
}
