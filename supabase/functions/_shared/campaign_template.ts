import type { Json } from "./db_types.ts";
import type { EndpointMessage } from "./types/whatsapp_endpoint_types.ts";

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
  delivery,
  to,
  recipient,
}: {
  template: Json;
  mapping: Json;
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

  const components: Array<{
    type: "header" | "body";
    parameters: Array<{ type: "text"; text: string }>;
  }> = [];

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
