import { assertEquals, assertThrows } from "./test_assert.ts";
import { parseTemplateDraftInput } from "./template_validation.ts";

Deno.test("template drafts preserve incomplete components", () => {
  assertEquals(
    parseTemplateDraftInput({
      name: "order_update",
      language: "en_US",
      category: "utility",
      components: [],
    }),
    {
      name: "order_update",
      language: "en_US",
      category: "UTILITY",
      components: [],
    },
  );
});

Deno.test("template submission accepts samples and quick replies", () => {
  const parsed = parseTemplateDraftInput(
    {
      name: "order_update",
      language: "en_US",
      category: "UTILITY",
      components: [
        {
          type: "BODY",
          text: "Hi {{1}}, order {{2}} is ready.",
          example: { body_text: [["Maria", "ORD-2048"]] },
        },
        {
          type: "BUTTONS",
          buttons: [{ type: "QUICK_REPLY", text: "View order" }],
        },
      ],
    },
    { requireComplete: true },
  );

  assertEquals(parsed.category, "UTILITY");
  assertEquals(parsed.components.length, 2);
});

Deno.test("template submission requires every variable sample", () => {
  assertThrows(
    () =>
      parseTemplateDraftInput(
        {
          name: "order_update",
          language: "en_US",
          category: "UTILITY",
          components: [
            {
              type: "BODY",
              text: "Hi {{1}}, order {{2}} is ready.",
              example: { body_text: [["Maria"]] },
            },
          ],
        },
        { requireComplete: true },
      ),
    "body requires a sample value for every variable",
  );
});

Deno.test("template submission rejects unsupported components", () => {
  assertThrows(
    () =>
      parseTemplateDraftInput(
        {
          name: "order_update",
          language: "en_US",
          category: "UTILITY",
          components: [
            { type: "BODY", text: "Your order is ready." },
            { type: "CAROUSEL", cards: [] },
          ],
        },
        { requireComplete: true },
      ),
    "unsupported template component: CAROUSEL",
  );
});
