import type {
  TemplateComponent,
  TemplateDraftInput,
} from "./types/whatsapp_template_types.ts";

const TEMPLATE_CATEGORIES = new Set([
  "AUTHENTICATION",
  "MARKETING",
  "UTILITY",
]);

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

function validateComponent(component: unknown): TemplateComponent {
  if (!isRecord(component) || typeof component.type !== "string") {
    throw new Error("template component is invalid");
  }

  switch (component.type) {
    case "HEADER": {
      if (
        component.format !== "TEXT" || typeof component.text !== "string" ||
        !component.text.trim() || component.text.length > 60
      ) {
        throw new Error("template text header is invalid");
      }

      const headerText = isRecord(component.example)
        ? component.example.header_text
        : undefined;
      requireSequentialVariables("header", component.text, headerText);
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
        component.buttons.some((button) =>
          !isRecord(button) || button.type !== "QUICK_REPLY" ||
          typeof button.text !== "string" || !button.text.trim() ||
          button.text.length > 25
        )
      ) {
        throw new Error("template quick-reply buttons are invalid");
      }
      return component as TemplateComponent;

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

  if (componentTypes.filter((type) => type === "BODY").length !== 1) {
    throw new Error("template requires exactly one body component");
  }

  if (new Set(componentTypes).size !== componentTypes.length) {
    throw new Error("template components cannot be duplicated");
  }

  return {
    name,
    language,
    category: category as TemplateDraftInput["category"],
    components,
  };
}
