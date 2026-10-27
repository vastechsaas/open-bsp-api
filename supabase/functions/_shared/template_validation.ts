import type {
  TemplateComponent,
  TemplateDraftInput,
} from "./types/whatsapp_template_types.ts";
import { canonicalCarousel } from "./carousel.ts";

const TEMPLATE_CATEGORIES = new Set([
  "AUTHENTICATION",
  "MARKETING",
  "UTILITY",
]);
const MEDIA_HEADER_FORMATS = new Set(["IMAGE", "VIDEO", "DOCUMENT"]);
const E164_PHONE_NUMBER = /^\+[1-9]\d{4,14}$/;
const DYNAMIC_URL_VARIABLE = "{{1}}";

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function variableIndexes(text: string): number[] {
  const indexes = new Set<number>();

  for (const match of text.matchAll(/\{\{\s*([0-9]+)\s*\}\}/g)) {
    indexes.add(Number(match[1]));
  }

  return [...indexes].sort((left, right) => left - right);
}

function requireSequentialVariables(
  section: "header" | "body",
  text: string,
  examples: unknown,
) {
  const indexes = variableIndexes(text);

  if (!indexes.length) return;

  if (indexes.some((index, position) => index !== position + 1)) {
    throw new Error(`${section} variables must be sequential from {{1}}`);
  }

  if (!Array.isArray(examples) || examples.length < indexes.length) {
    throw new Error(`${section} requires a sample value for every variable`);
  }

  if (
    indexes.some((_, position) =>
      typeof examples[position] !== "string" ||
      !examples[position].trim()
    )
  ) {
    throw new Error(`${section} variable samples cannot be empty`);
  }
}

function isHttpsUrl(value: string): boolean {
  try {
    const parsed = new URL(value.replace(DYNAMIC_URL_VARIABLE, "sample"));
    return parsed.protocol === "https:" && !!parsed.hostname;
  } catch {
    return false;
  }
}

function validateButton(button: unknown): boolean {
  if (
    !isRecord(button) || typeof button.text !== "string" ||
    !button.text.trim() || button.text.length > 25
  ) {
    return false;
  }

  if (button.type === "QUICK_REPLY") return true;

  if (button.type === "PHONE_NUMBER") {
    return typeof button.phone_number === "string" &&
      E164_PHONE_NUMBER.test(button.phone_number);
  }

  if (button.type !== "URL" || typeof button.url !== "string") return false;

  const occurrences = button.url.match(/\{\{1\}\}/g)?.length ?? 0;
  if (
    button.url.length > 2000 || !isHttpsUrl(button.url) || occurrences > 1 ||
    (occurrences === 1 && !button.url.endsWith(DYNAMIC_URL_VARIABLE))
  ) {
    return false;
  }

  if (occurrences === 0) return button.example === undefined;

  return Array.isArray(button.example) && button.example.length === 1 &&
    typeof button.example[0] === "string" && !!button.example[0].trim() &&
    isHttpsUrl(button.example[0]) && !button.example[0].includes("{{");
}

function validateComponent(component: unknown): TemplateComponent {
  if (!isRecord(component) || typeof component.type !== "string") {
    throw new Error("template component is invalid");
  }

  switch (component.type) {
    case "HEADER": {
      if (component.format === "TEXT") {
        if (
          typeof component.text !== "string" || !component.text.trim() ||
          component.text.length > 60
        ) {
          throw new Error("template text header is invalid");
        }

        const headerText = isRecord(component.example)
          ? component.example.header_text
          : undefined;
        requireSequentialVariables("header", component.text, headerText);
        return component as TemplateComponent;
      }

      if (!MEDIA_HEADER_FORMATS.has(String(component.format))) {
        throw new Error("template media header format is invalid");
      }
      if ("text" in component || "example" in component) {
        throw new Error(
          "template media header must not contain text or a retained sample",
        );
      }
      return component as TemplateComponent;
    }

    case "BODY": {
      if (
        typeof component.text !== "string" || !component.text.trim() ||
        component.text.length > 1024
      ) {
        throw new Error("template body is invalid");
      }

      const bodyText = isRecord(component.example) &&
          Array.isArray(component.example.body_text)
        ? component.example.body_text[0]
        : undefined;
      requireSequentialVariables("body", component.text, bodyText);
      return component as TemplateComponent;
    }

    case "FOOTER":
      if (
        typeof component.text !== "string" || !component.text.trim() ||
        component.text.length > 60
      ) {
        throw new Error("template footer is invalid");
      }
      return component as TemplateComponent;

    case "BUTTONS":
      if (
        !Array.isArray(component.buttons) || component.buttons.length < 1 ||
        component.buttons.length > 3 ||
        component.buttons.some((button) => !validateButton(button))
      ) {
        throw new Error("template buttons are invalid");
      }
      return component as TemplateComponent;

    case "CAROUSEL": {
      if (
        !Array.isArray(component.cards) || component.cards.length < 2 ||
        component.cards.length > 10
      ) {
        throw new Error("Carousel requires 2 to 10 cards");
      }
      component.cards.forEach((card, index) => {
        const fail = (message: string): never => {
          throw new Error(`Card ${index + 1}: ${message}`);
        };
        if (
          !isRecord(card) || !Array.isArray(card.components) ||
          card.components.length !== 3
        ) fail("requires an image, text and one website button");
        const rawParts = (card as { components: unknown[] }).components;
        if (
          rawParts.some((part) =>
            !isRecord(part) ||
            !["HEADER", "BODY", "BUTTONS"].includes(String(part.type))
          )
        ) fail("unsupported carousel component");
        const parts = rawParts.map(validateComponent);
        const header = parts.find((part) => part.type === "HEADER");
        const body = parts.find((part) => part.type === "BODY");
        const buttons = parts.find((part) => part.type === "BUTTONS");
        if (header?.format !== "IMAGE") {
          fail("an image is required; this carousel format is not supported");
        }
        if (!body || body.text.length > 160) {
          fail("card text must contain 1 to 160 characters");
        }
        if (
          !buttons || buttons.buttons.length !== 1 ||
          buttons.buttons[0].type !== "URL"
        ) fail("one website button is required");
        if (new Set(parts.map((part) => part.type)).size !== 3) {
          fail("components must not be repeated");
        }
      });
      return component as TemplateComponent;
    }

    default:
      throw new Error(`unsupported template component: ${component.type}`);
  }
}

export function parseTemplateDraftInput(
  value: unknown,
  options: { requireComplete?: boolean } = {},
): TemplateDraftInput {
  if (!isRecord(value)) throw new Error("template is required");

  const name = typeof value.name === "string" ? value.name.trim() : "";
  const language = typeof value.language === "string"
    ? value.language.trim()
    : "";
  const category = typeof value.category === "string"
    ? value.category.toUpperCase()
    : "";

  if (!name || !/^[a-z0-9_]+$/.test(name) || name.length > 512) {
    throw new Error(
      "template name must use lowercase letters, numbers, and underscores",
    );
  }

  if (!language) throw new Error("template language is required");
  if (!TEMPLATE_CATEGORIES.has(category)) {
    throw new Error("template category is invalid");
  }
  if (!Array.isArray(value.components)) {
    throw new Error("template components must be an array");
  }

  const carousel = value.components.find((part) =>
    isRecord(part) && part.type === "CAROUSEL"
  );
  if (carousel && category !== "MARKETING") {
    throw new Error("Image carousels require the Marketing category");
  }
  if (
    carousel &&
    (!isRecord(carousel) || !Array.isArray(carousel.cards) ||
      carousel.cards.length > 10)
  ) throw new Error("Carousel cards are invalid");
  if (
    isRecord(carousel) && Array.isArray(carousel.cards) &&
    carousel.cards.some((card) =>
      !isRecord(card) || !Array.isArray(card.components) ||
      card.components.some((part) =>
        !isRecord(part) ||
        !["HEADER", "BODY", "BUTTONS"].includes(String(part.type)) ||
        (part.type === "HEADER" && part.format !== "IMAGE")
      )
    )
  ) throw new Error("Unsupported image carousel card structure");

  if (!options.requireComplete) {
    return {
      name,
      language,
      category: category as TemplateDraftInput["category"],
      components: value.components as TemplateComponent[],
    };
  }

  const components = value.components.map(validateComponent);
  const componentTypes = components.map((component) => component.type);
  if (
    carousel &&
    (components.length !== 2 ||
      componentTypes.some((type) => type !== "BODY" && type !== "CAROUSEL"))
  ) {
    throw new Error("Image carousels support an introduction and cards only");
  }

  if (componentTypes.filter((type) => type === "BODY").length !== 1) {
    throw new Error("template requires exactly one body component");
  }

  if (new Set(componentTypes).size !== componentTypes.length) {
    throw new Error("template components cannot be duplicated");
  }

  const mediaHeader = components.find((component) =>
    component.type === "HEADER" && component.format !== "TEXT"
  );
  if (category === "AUTHENTICATION" && mediaHeader) {
    throw new Error("authentication templates cannot use media headers");
  }

  const buttons = components.find((component) => component.type === "BUTTONS");
  if (
    category === "AUTHENTICATION" &&
    buttons?.buttons.some((button) =>
      button.type === "URL" || button.type === "PHONE_NUMBER"
    )
  ) {
    throw new Error("authentication templates cannot use CTA buttons");
  }

  return canonicalCarousel({
    name,
    language,
    category: category as TemplateDraftInput["category"],
    components,
  });
}
