import type { JsonValue } from "./flow_definition.ts";

const VARIABLE_KEY_PATTERN = /^[a-z][a-z0-9_]{0,63}$/;

type TemplateToken = {
  readonly start: number;
  readonly end: number;
  readonly variable: string;
};

export type ChatbotTemplateParseResult =
  | {
    readonly ok: true;
    readonly variables: ReadonlyArray<string>;
    readonly tokens: ReadonlyArray<TemplateToken>;
  }
  | {
    readonly ok: false;
    readonly message: string;
    readonly index: number;
  };

export type ChatbotTemplateRenderResult =
  | { readonly ok: true; readonly text: string }
  | {
    readonly ok: false;
    readonly code:
      | "invalid_template_syntax"
      | "template_variable_missing"
      | "template_variable_not_scalar"
      | "rendered_template_blank"
      | "rendered_template_too_long";
    readonly message: string;
    readonly details: Readonly<Record<string, JsonValue>>;
  };

export function parseChatbotTemplate(
  template: string,
): ChatbotTemplateParseResult {
  const tokens: TemplateToken[] = [];
  const variables = new Set<string>();

  for (let index = 0; index < template.length;) {
    if (template.startsWith("}}", index)) {
      return {
        ok: false,
        message: "Unexpected closing template braces",
        index,
      };
    }
    if (!template.startsWith("{{", index)) {
      index += 1;
      continue;
    }

    const closeIndex = template.indexOf("}}", index + 2);
    if (closeIndex === -1) {
      return {
        ok: false,
        message: "Template variable is missing closing braces",
        index,
      };
    }

    const variable = template.slice(index + 2, closeIndex).trim();
    if (!VARIABLE_KEY_PATTERN.test(variable)) {
      return {
        ok: false,
        message:
          "Template variables must use lowercase snake_case names inside {{ }}",
        index,
      };
    }

    const end = closeIndex + 2;
    tokens.push({ start: index, end, variable });
    variables.add(variable);
    index = end;
  }

  return { ok: true, variables: [...variables], tokens };
}

export function renderChatbotTemplate(
  template: string,
  variables: Readonly<Record<string, JsonValue>>,
  maxLength: number,
): ChatbotTemplateRenderResult {
  const parsed = parseChatbotTemplate(template);
  if (!parsed.ok) {
    return {
      ok: false,
      code: "invalid_template_syntax",
      message: parsed.message,
      details: { index: parsed.index },
    };
  }

  let rendered = "";
  let cursor = 0;
  for (const token of parsed.tokens) {
    rendered += template.slice(cursor, token.start);
    if (!Object.hasOwn(variables, token.variable)) {
      return {
        ok: false,
        code: "template_variable_missing",
        message: `Template variable '${token.variable}' is missing`,
        details: { variable: token.variable },
      };
    }

    const value = variables[token.variable];
    if (
      typeof value !== "string" &&
      typeof value !== "number" &&
      typeof value !== "boolean"
    ) {
      return {
        ok: false,
        code: "template_variable_not_scalar",
        message:
          `Template variable '${token.variable}' must be text, a number, or a boolean`,
        details: { variable: token.variable },
      };
    }

    rendered += String(value);
    cursor = token.end;
  }
  rendered += template.slice(cursor);

  if (rendered.trim().length === 0) {
    return {
      ok: false,
      code: "rendered_template_blank",
      message: "Rendered template must not be blank",
      details: {},
    };
  }
  if (rendered.length > maxLength) {
    return {
      ok: false,
      code: "rendered_template_too_long",
      message: `Rendered template exceeds the ${maxLength} character limit`,
      details: { max_length: maxLength, rendered_length: rendered.length },
    };
  }

  return { ok: true, text: rendered };
}
