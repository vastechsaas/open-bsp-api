import type { Json } from "./db_types.ts";
import type { EndpointMessage } from "./types/whatsapp_endpoint_types.ts";
import type {
  Template,
  TemplateCarousel,
} from "./types/whatsapp_template_types.ts";
import { parseTemplateDraftInput } from "./template_validation.ts";
import { canonicalCarousel } from "./carousel.ts";
import type { TemplateDraftInput } from "./types/whatsapp_template_types.ts";

type JsonRecord = Record<string, Json | undefined>;

export type CampaignTemplateDelivery = {
  contactAddress: string;
  contactName: string | null;
  variables: Json;
};

function asRecord(value: Json): JsonRecord {
  if (!value || Array.isArray(value) || typeof value !== "object") return {};
  return value as JsonRecord;
}

function mappedValue(
  source: string,
  delivery: CampaignTemplateDelivery,
): string {
  let value: Json | undefined;

  if (source === "contact.name") {
    value = delivery.contactName;
  } else if (source === "contact.address") {
    value = delivery.contactAddress;
  } else if (source.startsWith("csv.")) {
    value = asRecord(delivery.variables)[source.slice(4)];
  } else {
    throw new Error(`Unsupported campaign variable mapping: ${source}`);
  }

  if (value === null || value === undefined || value === "") {
    throw new Error(`Campaign variable ${source} has no value`);
  }

  return typeof value === "string" ? value : JSON.stringify(value);
}

function placeholderIndexes(text: string): number[] {
  const indexes = new Set<number>();

  for (const match of text.matchAll(/\{\{\s*([0-9]+)\s*\}\}/g)) {
    indexes.add(Number(match[1]));
  }

  return [...indexes].sort((left, right) => left - right);
}

export function buildCampaignTemplatePayload({
  template,
  mapping,
  headerMedia,
  carouselMedia,
  delivery,
  to,
  recipient,
}: {
  template: Json;
  mapping: Json;
  headerMedia?: Json;
  carouselMedia?: Json;
  delivery: CampaignTemplateDelivery;
  to?: string;
  recipient?: string;
}): EndpointMessage {
  const templateRecord = asRecord(template);
  const mappingRecord = asRecord(mapping);
  const name = templateRecord.name;
  const language = templateRecord.language;
  const rawComponents = templateRecord.components;

  if (typeof name !== "string" || typeof language !== "string") {
    throw new Error("Campaign template name or language is invalid");
  }

  if (!to && !recipient) {
    throw new Error("Campaign recipient is missing");
  }

  const components: NonNullable<Template["components"]> = [];

  if (
    Array.isArray(rawComponents) &&
    rawComponents.some((part) => asRecord(part).type === "CAROUSEL")
  ) {
    const definition = parseTemplateDraftInput(
      canonicalCarousel(template as unknown as TemplateDraftInput),
      { requireComplete: true },
    );
    const carousel = definition.components.find((part) =>
      part.type === "CAROUSEL"
    )!;
    const images = Array.isArray(carouselMedia)
      ? carouselMedia.map(asRecord)
      : [];
    if (images.length !== carousel.cards.length) {
      throw new Error("Every carousel card requires an image");
    }
    const cards: TemplateCarousel["cards"] = carousel.cards.map(
      (card, cardIndex) => {
        const image = images.find((asset) => asset.card_index === cardIndex);
        if (!image || typeof image.media_id !== "string" || !image.media_id) {
          throw new Error(`Card ${cardIndex + 1}: image is missing`);
        }
        const parts: TemplateCarousel["cards"][number]["components"] = [
          {
            type: "header",
            parameters: [{ type: "image", image: { id: image.media_id } }],
          },
        ];
        const body = card.components.find((part) => part.type === "BODY")!;
        const parameters = placeholderIndexes(body.text).map((index) => {
          const key = `carousel.${cardIndex}.body.${index}`;
          if (typeof mappingRecord[key] !== "string") {
            throw new Error(`Campaign template variable ${key} is not mapped`);
          }
          return {
            type: "text" as const,
            text: mappedValue(mappingRecord[key] as string, delivery),
          };
        });
        const resolvedBody = body.text.replace(
          /\{\{\s*([0-9]+)\s*\}\}/g,
          (_, index) =>
            parameters[placeholderIndexes(body.text).indexOf(Number(index))]
              .text,
        );
        if (resolvedBody.length > 160) {
          throw new Error(
            `Card ${cardIndex + 1}: personalized text exceeds 160 characters`,
          );
        }
        if (parameters.length) parts.push({ type: "body", parameters });
        const button = card.components.find((part) =>
          part.type === "BUTTONS"
        )!.buttons[0];
        if (button.type === "URL" && button.url.endsWith("{{1}}")) {
          const key = `carousel.${cardIndex}.button.0.1`;
          if (typeof mappingRecord[key] !== "string") {
            throw new Error(`Campaign template variable ${key} is not mapped`);
          }
          const text = mappedValue(mappingRecord[key] as string, delivery);
          const url = new URL(button.url.replace("{{1}}", text));
          if (
            url.protocol !== "https:" ||
            !url.href.startsWith(button.url.slice(0, -5))
          ) throw new Error(`Card ${cardIndex + 1}: URL variable is invalid`);
          parts.push({
            type: "button",
            sub_type: "url",
            index: "0",
            parameters: [{ type: "text", text }],
          });
        }
        return { card_index: cardIndex, components: parts };
      },
    );
    components.push({ type: "carousel", cards });
  }

  const media = asRecord(headerMedia ?? null);
  if (Array.isArray(rawComponents)) {
    const mediaHeader = rawComponents.map(asRecord).find((component) =>
      component.type === "HEADER" &&
      ["IMAGE", "VIDEO", "DOCUMENT"].includes(String(component.format))
    );
    if (mediaHeader) {
      const format = mediaHeader.format;
      if (media.format !== format || typeof media.media_id !== "string") {
        throw new Error(
          "Campaign media is missing or does not match the template header",
        );
      }
      const parameter = format === "IMAGE"
        ? { type: "image" as const, image: { id: media.media_id } }
        : format === "VIDEO"
        ? { type: "video" as const, video: { id: media.media_id } }
        : {
          type: "document" as const,
          document: {
            id: media.media_id,
            ...(typeof media.file_name === "string"
              ? { filename: media.file_name }
              : {}),
          },
        };
      components.push({ type: "header", parameters: [parameter] });
    }
  }

  if (Array.isArray(rawComponents)) {
    for (const rawComponent of rawComponents) {
      const component = asRecord(rawComponent);
      if (
        component.type !== "HEADER" && component.type !== "BODY" ||
        typeof component.text !== "string"
      ) {
        continue;
      }

      const section = component.type.toLowerCase() as "header" | "body";
      const parameters = placeholderIndexes(component.text).map((index) => {
        const mappingKey = `${section}.${index}`;
        const source = mappingRecord[mappingKey];

        if (typeof source !== "string") {
          throw new Error(
            `Campaign template variable ${mappingKey} is not mapped`,
          );
        }

        return {
          type: "text" as const,
          text: mappedValue(source, delivery),
        };
      });

      if (parameters.length) components.push({ type: section, parameters });
    }

    for (const rawComponent of rawComponents) {
      const component = asRecord(rawComponent);
      if (component.type !== "BUTTONS" || !Array.isArray(component.buttons)) {
        continue;
      }

      component.buttons.forEach((rawButton, buttonIndex) => {
        const button = asRecord(rawButton);
        if (
          button.type !== "URL" || typeof button.url !== "string" ||
          !button.url.endsWith("{{1}}")
        ) {
          return;
        }

        const mappingKey = `button.${buttonIndex}.1`;
        const source = mappingRecord[mappingKey];
        if (typeof source !== "string") {
          throw new Error(
            `Campaign template variable ${mappingKey} is not mapped`,
          );
        }

        components.push({
          type: "button",
          sub_type: "url",
          index: String(buttonIndex),
          parameters: [{
            type: "text",
            text: mappedValue(source, delivery),
          }],
        });
      });
    }
  }

  return {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to,
    recipient,
    type: "template",
    template: {
      name,
      language: { code: language, policy: "deterministic" },
      ...(components.length ? { components } : {}),
    },
  };
}
