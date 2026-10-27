import { assertEquals, assertThrows as checkThrows } from "./test_assert.ts";
import { canonicalCarousel, parseCarouselAssets } from "./carousel.ts";
import { parseTemplateDraftInput } from "./template_validation.ts";
import { buildCampaignTemplatePayload } from "./campaign_template.ts";
import type { Json } from "./db_types.ts";
import type { TemplateDraftInput } from "./types/whatsapp_template_types.ts";
const assertThrows = (fn: () => unknown) => checkThrows(fn, "");

function definition(count = 2): TemplateDraftInput {
  return {
    name: "image_offers",
    language: "en_US",
    category: "MARKETING",
    components: [
      { type: "BODY", text: "Our offers" },
      {
        type: "CAROUSEL",
        cards: Array.from({ length: count }, () => ({
          components: [
            { type: "HEADER", format: "IMAGE" },
            {
              type: "BODY",
              text: "Hello {{1}}",
              example: { body_text: [["Customer"]] },
            },
            {
              type: "BUTTONS",
              buttons: [{
                type: "URL",
                text: "Shop",
                url: "https://example.com/products/{{1}}",
                example: ["https://example.com/products/one"],
              }],
            },
          ],
        })),
      },
    ],
  };
}

Deno.test("image carousel accepts 2–10 consistently structured cards", () => {
  for (const count of [2, 10]) {
    assertEquals(
      parseTemplateDraftInput(definition(count), { requireComplete: true })
        .components.length,
      2,
    );
  }
  for (const count of [0, 1, 11]) {
    assertThrows(() =>
      parseTemplateDraftInput(definition(count), { requireComplete: true })
    );
  }
  assertThrows(() =>
    parseTemplateDraftInput({ ...definition(), category: "UTILITY" }, {
      requireComplete: true,
    })
  );
});

Deno.test("each carousel field and unsupported imported variants are validated", () => {
  for (
    const replacement of [
      { type: "HEADER", format: "VIDEO" },
      { type: "BODY", text: "" },
      { type: "BODY", text: "x".repeat(161) },
      { type: "BODY", text: "Hi {{1}}" },
      { type: "BUTTONS", buttons: [] },
      {
        type: "BUTTONS",
        buttons: [{ type: "URL", text: "Shop", url: "http://example.com" }],
      },
    ]
  ) {
    const input = definition();
    const carousel = input.components.find((part) => part.type === "CAROUSEL")!;
    const index = replacement.type === "HEADER"
      ? 0
      : replacement.type === "BODY"
      ? 1
      : 2;
    carousel.cards[0].components[index] =
      replacement as typeof carousel.cards[0]["components"][number];
    assertThrows(() =>
      parseTemplateDraftInput(input, { requireComplete: true })
    );
  }
});

Deno.test("tenant-owned asset references strip unknown fields and reject cross-tenant files", () => {
  const org = "11111111-1111-4111-8111-111111111111";
  const asset = {
    card_id: crypto.randomUUID(),
    storage_uri: `internal://media/organizations/${org}/attachments/${
      "a".repeat(43)
    }`,
    file_name: "image.png",
    mime_type: "image/png",
    size: 42,
  };
  assertEquals(
    parseCarouselAssets([{ ...asset, secret: "not retained" }], org),
    [asset],
  );
  assertThrows(() => parseCarouselAssets([asset], crypto.randomUUID()));
  assertThrows(() => parseCarouselAssets([asset, asset], org));
  assertThrows(() => parseCarouselAssets([{ ...asset, size: 5242881 }], org));
});

Deno.test("campaign carousel uses ordered card indexes and independent recipient variables without internal references", () => {
  const input = definition();
  const clean = canonicalCarousel(input);
  const payload = buildCampaignTemplatePayload({
    template: clean as unknown as Json,
    mapping: {
      "carousel.0.body.1": "contact.name",
      "carousel.1.body.1": "csv.greeting",
      "carousel.0.button.0.1": "csv.product",
      "carousel.1.button.0.1": "csv.product",
    },
    carouselMedia: [{
      card_index: 0,
      media_id: "first",
      storage_uri: "PRIVATE",
    }, { card_index: 1, media_id: "second" }],
    delivery: {
      contactAddress: "15551234567",
      contactName: "Customer",
      variables: { greeting: "Friend", product: "one" },
    },
    to: "15551234567",
  });
  const serialized = JSON.stringify(payload);
  assertEquals(serialized.includes("PRIVATE"), false);
  assertEquals(serialized.includes('"card_index":1'), true);
  assertEquals(serialized.includes('"text":"Friend"'), true);
  assertThrows(() =>
    buildCampaignTemplatePayload({
      template: clean as unknown as Json,
      mapping: {},
      carouselMedia: [],
      delivery: { contactAddress: "1", contactName: null, variables: {} },
      to: "1",
    })
  );
});
