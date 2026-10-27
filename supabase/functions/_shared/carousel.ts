import type {
  CarouselComponent,
  CarouselMediaAsset,
  TemplateDraftInput,
} from "./types/whatsapp_template_types.ts";

export function imageCarousel(
  template: { components?: unknown },
): CarouselComponent | undefined {
  return Array.isArray(template.components)
    ? template.components.find((part) => part?.type === "CAROUSEL")
    : undefined;
}

export function assertOwnedCarouselAsset(uri: string, organizationId: string) {
  const prefix =
    `internal://media/organizations/${organizationId}/attachments/`;
  if (
    !uri.startsWith(prefix) ||
    !/^[A-Za-z0-9_-]{43}$/.test(uri.slice(prefix.length))
  ) {
    throw new Error("Carousel image does not belong to this organization");
  }
}

export function parseCarouselAssets(
  value: unknown,
  organizationId: string,
): CarouselMediaAsset[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 10) {
    throw new Error("Carousel media must contain at most 10 images");
  }
  const ids = new Set<string>();
  return value.map((asset) => {
    if (
      !asset || typeof asset !== "object" ||
      typeof asset.card_id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        asset.card_id,
      ) || ids.has(asset.card_id) ||
      typeof asset.storage_uri !== "string" ||
      typeof asset.file_name !== "string" ||
      !["image/jpeg", "image/png"].includes(asset.mime_type) ||
      !Number.isInteger(asset.size) || asset.size < 1 ||
      asset.size > 5 * 1024 * 1024
    ) {
      throw new Error("Carousel image reference is invalid");
    }
    assertOwnedCarouselAsset(asset.storage_uri, organizationId);
    ids.add(asset.card_id);
    return {
      card_id: asset.card_id,
      storage_uri: asset.storage_uri,
      file_name: asset.file_name,
      mime_type: asset.mime_type,
      size: asset.size,
    };
  });
}

/** Empty slots preserve stable card identities in incomplete drafts. Sending still requires full assets. */
export function parseCarouselDraftAssets(
  value: unknown,
  organizationId: string,
): (CarouselMediaAsset | { card_id: string })[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 10) {
    throw new Error("Carousel media must contain at most 10 images");
  }
  const ids = new Set<string>();
  return value.map((item) => {
    if (
      !item || typeof item.card_id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        item.card_id,
      ) || ids.has(item.card_id)
    ) throw new Error("Carousel card identity is invalid");
    ids.add(item.card_id);
    return item.storage_uri === undefined
      ? { card_id: item.card_id }
      : parseCarouselAssets([item], organizationId)[0];
  });
}

/** Only Meta definition fields are retained; internal UI/asset state stays separate. */
export function canonicalCarousel(
  template: TemplateDraftInput,
): TemplateDraftInput {
  const carousel = imageCarousel(template);
  if (!carousel) return template;
  if (
    !Array.isArray(carousel.cards) ||
    carousel.cards.some((card) => !Array.isArray(card?.components))
  ) return template;
  return {
    name: template.name,
    language: template.language,
    category: template.category,
    components: template.components.map((part) =>
      part.type !== "CAROUSEL"
        ? (part.type === "BODY"
          ? {
            type: "BODY",
            text: part.text,
            ...(part.example ? { example: part.example } : {}),
          }
          : part)
        : {
          type: "CAROUSEL",
          cards: part.cards.map((card) => ({
            components: card.components.map((component) => {
              if (component.type === "HEADER") {
                return component.format === "TEXT"
                  ? component
                  : { type: "HEADER" as const, format: component.format };
              }
              if (component.type === "BODY") {
                return {
                  type: "BODY" as const,
                  text: component.text,
                  ...(component.example ? { example: component.example } : {}),
                };
              }
              if (component.type !== "BUTTONS") return component;
              return {
                type: "BUTTONS" as const,
                buttons: component.buttons.map((button) =>
                  button.type === "URL"
                    ? {
                      type: "URL" as const,
                      text: button.text,
                      url: button.url,
                      ...(button.example ? { example: button.example } : {}),
                    }
                    : button
                ),
              };
            }),
          })),
        }
    ),
  };
}
