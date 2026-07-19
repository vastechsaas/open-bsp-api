import { assertEquals, assertThrows } from "./test_assert.ts";
import { buildCampaignTemplatePayload } from "./campaign_template.ts";

Deno.test("buildCampaignTemplatePayload maps contact and CSV values", () => {
  const payload = buildCampaignTemplatePayload({
    template: {
      id: "template-1",
      name: "order_update",
      language: "en_US",
      status: "APPROVED",
      components: [
        { type: "HEADER", text: "Hello {{1}}" },
        { type: "BODY", text: "Order {{1}} for {{2}}" },
      ],
    },
    mapping: {
      "header.1": "contact.name",
      "body.1": "csv.order_id",
      "body.2": "contact.address",
    },
    delivery: {
      contactAddress: "15551110001",
      contactName: "Alice",
      variables: { order_id: 42 },
    },
    to: "15551110001",
  });

  assertEquals(payload, {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: "15551110001",
    recipient: undefined,
    type: "template",
    template: {
      name: "order_update",
      language: { code: "en_US", policy: "deterministic" },
      components: [
        {
          type: "header",
          parameters: [{ type: "text", text: "Alice" }],
        },
        {
          type: "body",
          parameters: [
            { type: "text", text: "42" },
            { type: "text", text: "15551110001" },
          ],
        },
      ],
    },
  });
});

Deno.test("buildCampaignTemplatePayload rejects missing recipient values", () => {
  assertThrows(
    () =>
      buildCampaignTemplatePayload({
        template: {
          id: "template-1",
          name: "welcome",
          language: "en_US",
          status: "APPROVED",
          components: [{ type: "BODY", text: "Hello {{1}}" }],
        },
        mapping: { "body.1": "contact.name" },
        delivery: {
          contactAddress: "15551110001",
          contactName: null,
          variables: {},
        },
        to: "15551110001",
      }),
    "Campaign variable contact.name has no value",
  );
});

for (
  const media of [
    { format: "IMAGE", type: "image", value: { id: "media-image" } },
    { format: "VIDEO", type: "video", value: { id: "media-video" } },
    {
      format: "DOCUMENT",
      type: "document",
      value: { id: "media-pdf", filename: "offer.pdf" },
    },
  ] as const
) {
  Deno.test(`buildCampaignTemplatePayload adds ${media.type} header media`, () => {
    const mediaId = `media-${media.type === "document" ? "pdf" : media.type}`;
    const payload = buildCampaignTemplatePayload({
      template: {
        id: "template-media",
        name: "promotion",
        language: "en_US",
        status: "APPROVED",
        components: [
          { type: "HEADER", format: media.format },
          { type: "BODY", text: "Hello" },
        ],
      },
      mapping: {},
      headerMedia: {
        format: media.format,
        media_id: mediaId,
        file_name: media.format === "DOCUMENT" ? "offer.pdf" : "asset",
        mime_type: "test/type",
        size: 1,
      },
      delivery: {
        contactAddress: "15551110001",
        contactName: "Alice",
        variables: {},
      },
      to: "15551110001",
    });

    if (payload.type !== "template") {
      throw new Error("Expected template payload");
    }
    assertEquals(payload.template.components?.[0], {
      type: "header",
      parameters: [{ type: media.type, [media.type]: media.value }],
    });
  });
}
