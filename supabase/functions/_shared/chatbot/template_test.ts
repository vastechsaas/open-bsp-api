import { assertEquals } from "../test_assert.ts";
import { parseChatbotTemplate, renderChatbotTemplate } from "./template.ts";

Deno.test("parses restricted template variables and deduplicates names", () => {
  const result = parseChatbotTemplate(
    "Hello {{ customer_name }} from {{city}} and {{city}}",
  );
  if (!result.ok) throw new Error(result.message);

  assertEquals(result.variables, ["customer_name", "city"]);
});

Deno.test("rejects malformed braces and expression syntax", () => {
  for (
    const template of [
      "Hello {{city",
      "Hello city}}",
      "Hello {{contact.city}}",
      "Hello {{city || 'unknown'}}",
      "Hello {{ City }}",
    ]
  ) {
    assertEquals(parseChatbotTemplate(template).ok, false);
  }
});

Deno.test("renders string, number, and boolean values without evaluating code", () => {
  assertEquals(
    renderChatbotTemplate(
      "{{name}} has {{count}} items; active={{active}}",
      { name: "Amina", count: 3, active: true },
      100,
    ),
    { ok: true, text: "Amina has 3 items; active=true" },
  );
});

Deno.test("fails safely for missing and non-scalar variables", () => {
  const missing = renderChatbotTemplate("Hello {{name}}", {}, 100);
  assertEquals(missing.ok, false);
  if (!missing.ok) assertEquals(missing.code, "template_variable_missing");

  const objectValue = renderChatbotTemplate(
    "Hello {{contact}}",
    { contact: { name: "Amina" } },
    100,
  );
  assertEquals(objectValue.ok, false);
  if (!objectValue.ok) {
    assertEquals(objectValue.code, "template_variable_not_scalar");
  }
});

Deno.test("enforces post-render blank and length limits", () => {
  const blank = renderChatbotTemplate("{{value}}", { value: "   " }, 100);
  assertEquals(blank.ok, false);
  if (!blank.ok) assertEquals(blank.code, "rendered_template_blank");

  const tooLong = renderChatbotTemplate(
    "Hi {{name}}",
    { name: "abcdefghij" },
    5,
  );
  assertEquals(tooLong.ok, false);
  if (!tooLong.ok) assertEquals(tooLong.code, "rendered_template_too_long");
});
