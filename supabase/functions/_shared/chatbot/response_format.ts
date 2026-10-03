/** Portable contract shared with the builder preview and standalone Node engine.
 * No eval, scripts, session variables, secrets, HTML or network access.
 */
export const RESPONSE_FORMAT_MAX_LENGTH = 4096;
export const RESPONSE_FORMAT_MAX_ITEMS = 50;

export type ResponseListFormat = {
  kind: "list";
  item_template: string;
  separator: string;
  array_separator: string;
  empty_text: string;
  max_items: number;
};

export type ResponseFormatResult =
  | { ok: true; text: string }
  | { ok: false; code: string };

const unsafeKeys = new Set(["__proto__", "constructor", "prototype"]);
export function isResponsePath(path: string): boolean {
  return path === "$" ||
    /^[A-Za-z_][A-Za-z0-9_]*(?:\.(?:[A-Za-z_][A-Za-z0-9_]*|0|[1-9][0-9]*))*$/
        .test(path) && !path.split(".").some((part) => unsafeKeys.has(part));
}

export function responseValueAtPath(value: unknown, path: string): unknown {
  if (!isResponsePath(path)) return undefined;
  if (path === "$") return value;
  return path.split(".").reduce<unknown>((current, part) => {
    if (
      typeof current !== "object" || current === null ||
      !Object.hasOwn(current, part)
    ) return undefined;
    return (current as Record<string, unknown>)[part];
  }, value);
}

function templateParts(template: string): string[] | null {
  const parts = template.split(/(\{\{[\s\S]*?\}\})/);
  for (const part of parts) {
    if (part.startsWith("{{") && part.endsWith("}}")) {
      const key = part.slice(2, -2).trim();
      if (
        key !== "index" && key !== "item" && key !== "response" &&
        !((key.startsWith("item.") || key.startsWith("response.")) &&
          isResponsePath(key))
      ) return null;
    } else if (part.includes("{{") || part.includes("}}")) return null;
  }
  return parts;
}

export function isResponseListFormat(
  value: unknown,
): value is ResponseListFormat {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const format = value as Record<string, unknown>;
  const keys = [
    "kind",
    "item_template",
    "separator",
    "array_separator",
    "empty_text",
    "max_items",
  ];
  return Object.keys(format).every((key) => keys.includes(key)) &&
    format.kind === "list" &&
    typeof format.item_template === "string" &&
    !!format.item_template.trim() && format.item_template.length <= 2000 &&
    templateParts(format.item_template) !== null &&
    typeof format.separator === "string" && format.separator.length <= 32 &&
    typeof format.array_separator === "string" &&
    format.array_separator.length <= 32 &&
    typeof format.empty_text === "string" && !!format.empty_text.trim() &&
    format.empty_text.length <= 500 &&
    typeof format.max_items === "number" &&
    Number.isInteger(format.max_items) &&
    format.max_items >= 1 && format.max_items <= RESPONSE_FORMAT_MAX_ITEMS;
}

function scalarText(value: unknown): string | undefined {
  if (
    typeof value === "string" || typeof value === "boolean" ||
    typeof value === "number" && Number.isFinite(value)
  ) return String(value);
  return undefined;
}

/** All items/fields are required. Invalid/oversized results fail, never silently
 * truncate a catalogue or emit raw objects. Empty arrays use configured copy.
 */
export function formatResponseList(
  value: unknown,
  response: unknown,
  format: ResponseListFormat,
): ResponseFormatResult {
  const fail = (code: string): ResponseFormatResult => ({ ok: false, code });
  if (!isResponseListFormat(format)) return fail("response_format_invalid");
  if (!Array.isArray(value)) return fail("response_format_array_required");
  if (value.length > format.max_items) {
    return fail("response_format_too_many_items");
  }
  if (value.length === 0) return { ok: true, text: format.empty_text };
  const parts = templateParts(format.item_template)!;
  const rendered: string[] = [];
  let length = 0;
  for (const [index, item] of value.entries()) {
    let text = "";
    for (const part of parts) {
      if (!part.startsWith("{{")) {
        text += part;
      } else {
        const path = part.slice(2, -2).trim();
        const field: unknown = path === "index"
          ? index + 1
          : path === "item"
          ? item
          : path === "response"
          ? response
          : path.startsWith("item.")
          ? responseValueAtPath(item, path.slice(5))
          : responseValueAtPath(response, path.slice(9));
        if (field === undefined || field === null) {
          return fail("response_format_field_missing");
        }
        const values = Array.isArray(field) ? field : [field];
        if (values.length > RESPONSE_FORMAT_MAX_ITEMS) {
          return fail("response_format_too_many_items");
        }
        const strings = values.map(scalarText);
        if (strings.some((entry) => entry === undefined)) {
          return fail("response_format_scalar_required");
        }
        text += strings.join(format.array_separator);
      }
      if (text.length > RESPONSE_FORMAT_MAX_LENGTH) {
        return fail("response_format_too_long");
      }
    }
    if (!text.trim()) return fail("response_format_blank");
    length += text.length + (index > 0 ? format.separator.length : 0);
    if (length > RESPONSE_FORMAT_MAX_LENGTH) {
      return fail("response_format_too_long");
    }
    rendered.push(text);
  }
  return { ok: true, text: rendered.join(format.separator) };
}
