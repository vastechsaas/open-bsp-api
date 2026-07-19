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

Deno.test("utility and marketing templates accept website and phone CTA buttons", () => {
  for (const category of ["UTILITY", "MARKETING"]) {
    const parsed = parseTemplateDraftInput(
      {
        name: "order_update",
        language: "en_US",
        category,
        components: [
          { type: "BODY", text: "Your order is ready." },
          {
            type: "BUTTONS",
            buttons: [
              {
                type: "URL",
                text: "Track order",
                url: "https://example.com/orders",
              },
              {
                type: "URL",
                text: "View order",
                url: "https://example.com/orders/{{1}}",
                example: ["https://example.com/orders/ORD-2048"],
              },
              {
                type: "PHONE_NUMBER",
                text: "Call us",
                phone_number: "+15551234567",
              },
            ],
          },
        ],
      },
      { requireComplete: true },
    );

    assertEquals(parsed.components.length, 2);
  }
});

for (
  const [button, label] of [
    [{ type: "URL", text: "Open", url: "http://example.com" }, "non-HTTPS URL"],
    [
      { type: "URL", text: "Open", url: "https://example.com/{{1}}" },
      "missing dynamic URL sample",
    ],
    [{
      type: "URL",
      text: "Open",
      url: "https://example.com/{{1}}/details",
      example: ["https://example.com/1/details"],
    }, "non-suffix dynamic variable"],
    [
      { type: "PHONE_NUMBER", text: "Call", phone_number: "555-1234" },
      "non-E.164 phone number",
    ],
  ] as const
) {
  Deno.test(`template submission rejects ${label}`, () => {
    assertThrows(
      () =>
        parseTemplateDraftInput(
          {
            name: "order_update",
            language: "en_US",
            category: "UTILITY",
            components: [
              { type: "BODY", text: "Your order is ready." },
              { type: "BUTTONS", buttons: [button] },
            ],
          },
          { requireComplete: true },
        ),
      "template buttons are invalid",
    );
  });
}

Deno.test("authentication templates reject CTA buttons", () => {
  assertThrows(
    () =>
      parseTemplateDraftInput(
        {
          name: "login_code",
          language: "en_US",
          category: "AUTHENTICATION",
          components: [
            { type: "BODY", text: "Your login code is 1234." },
            {
              type: "BUTTONS",
              buttons: [{
                type: "URL",
                text: "Open",
                url: "https://example.com",
              }],
            },
          ],
        },
        { requireComplete: true },
      ),
    "authentication templates cannot use CTA buttons",
  );
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

Deno.test("utility and marketing templates accept media headers without retained samples", () => {
  for (const category of ["UTILITY", "MARKETING"]) {
    for (const format of ["IMAGE", "VIDEO", "DOCUMENT"]) {
      const parsed = parseTemplateDraftInput(
        {
          name: "media_update",
          language: "en_US",
          category,
          components: [
            { type: "HEADER", format },
            { type: "BODY", text: "Your update is ready." },
          ],
        },
        { requireComplete: true },
      );
      assertEquals(parsed.components[0], { type: "HEADER", format });
    }
  }
});

Deno.test("authentication templates reject media headers", () => {
  assertThrows(
    () =>
      parseTemplateDraftInput(
        {
          name: "login_code",
          language: "en_US",
          category: "AUTHENTICATION",
          components: [
            { type: "HEADER", format: "IMAGE" },
            { type: "BODY", text: "Your login code is 1234." },
          ],
        },
        { requireComplete: true },
      ),
    "authentication templates cannot use media headers",
  );
});

Deno.test("media headers reject client-retained handles", () => {
  assertThrows(
    () =>
      parseTemplateDraftInput(
        {
          name: "media_update",
          language: "en_US",
          category: "UTILITY",
          components: [
            {
              type: "HEADER",
              format: "DOCUMENT",
              example: { header_handle: ["should-not-be-retained"] },
            },
            { type: "BODY", text: "Your statement is ready." },
          ],
        },
        { requireComplete: true },
      ),
    "template media header must not contain text or a retained sample",
  );
});
