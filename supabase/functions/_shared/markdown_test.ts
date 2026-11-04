import { assertEquals } from "./test_assert.ts";
import { whatsappToMarkdown } from "./markdown.ts";

Deno.test("incoming WhatsApp formatting preserves URLs when storing chat text", () => {
  const url = "https://example.com/a_b_c?utm_source=chat&utm_medium=reply";
  assertEquals(whatsappToMarkdown(`*Offer* ${url}.`), `**Offer** ${url}.`);
});
