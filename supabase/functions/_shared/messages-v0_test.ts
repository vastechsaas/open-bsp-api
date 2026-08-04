import { assertEquals } from "jsr:@std/assert";
import type { MessageRow } from "./supabase.ts";
import { fromV1, type MessageRowV0, toV1 } from "./messages-v0.ts";
import type { OutgoingInteractive } from "./types/whatsapp_endpoint_types.ts";

function incomingV0(type: string, data: unknown): MessageRowV0 {
  return {
    id: "message-1",
    conversation_id: "conversation-1",
    organization_id: "organization-1",
    direction: "incoming",
    content: { type, [type]: data },
  } as unknown as MessageRowV0;
}

Deno.test("legacy messages preserve core interactive replies", () => {
  const flowReply = {
    type: "nfm_reply",
    nfm_reply: {
      name: "flow",
      body: "Response submitted",
      response_json: '{"secret":"kept for backend routing"}',
    },
  } as const;

  assertEquals(toV1(incomingV0("interactive", flowReply))?.content, {
    version: "1",
    type: "data",
    kind: "interactive",
    data: flowReply,
    artifacts: undefined,
  });

  const malformedFlowReply = {
    ...flowReply,
    nfm_reply: { ...flowReply.nfm_reply, response_json: "{not-json" },
  };
  assertEquals(
    toV1(incomingV0("interactive", malformedFlowReply))?.content,
    {
      version: "1",
      type: "data",
      kind: "interactive",
      data: malformedFlowReply,
      artifacts: undefined,
    },
  );
});

Deno.test("legacy messages preserve order and location data", () => {
  const order = {
    catalog_id: "catalog-1",
    product_items: [{
      product_retailer_id: "product-1",
      quantity: "2",
      item_price: "12.50",
      currency: "USD",
    }],
    text: "Your order",
  };
  const location = {
    name: "Main office",
    address: "1 Example Street",
    latitude: 1.25,
    longitude: 2.5,
    url: "https://example.com/location",
  };

  assertEquals(toV1(incomingV0("order", order))?.content, {
    version: "1",
    type: "data",
    kind: "order",
    data: order,
    artifacts: undefined,
  });
  assertEquals(toV1(incomingV0("location", location))?.content, {
    version: "1",
    type: "data",
    kind: "location",
    data: location,
    artifacts: undefined,
  });
});

Deno.test("v1 product messages remain structured in the legacy mirror", () => {
  const interactive = {
    type: "product",
    body: { text: "Featured product" },
    action: {
      catalog_id: "catalog-1",
      product_retailer_id: "product-1",
    },
  };
  const row = {
    id: "message-1",
    conversation_id: "conversation-1",
    organization_id: "organization-1",
    direction: "outgoing",
    content: {
      version: "1",
      type: "data",
      kind: "interactive",
      data: interactive,
    },
  } as unknown as MessageRow;

  assertEquals(fromV1(row)?.content as unknown, {
    version: "0",
    type: "interactive",
    interactive,
    artifacts: undefined,
  });
});

Deno.test("core outgoing interactive contracts remain discriminated", () => {
  const messages = [
    {
      type: "interactive",
      interactive: {
        type: "product",
        action: {
          catalog_id: "catalog-1",
          product_retailer_id: "product-1",
        },
      },
    },
    {
      type: "interactive",
      interactive: {
        type: "product_list",
        header: { type: "text", text: "Featured" },
        body: { text: "Choose a product" },
        action: {
          catalog_id: "catalog-1",
          sections: [{
            title: "Popular",
            product_items: [{ product_retailer_id: "product-1" }],
          }],
        },
      },
    },
    {
      type: "interactive",
      interactive: {
        type: "catalog_message",
        body: { text: "Browse our catalog" },
        action: {
          name: "catalog_message",
          parameters: { thumbnail_product_retailer_id: "product-1" },
        },
      },
    },
    {
      type: "interactive",
      interactive: {
        type: "location_request_message",
        body: { text: "Share your location" },
        action: { name: "send_location" },
      },
    },
    {
      type: "interactive",
      interactive: {
        type: "flow",
        body: { text: "Complete the form" },
        action: {
          name: "flow",
          parameters: {
            flow_message_version: "3",
            flow_token: "opaque-token",
            flow_id: "flow-1",
            flow_cta: "Open form",
            flow_action: "navigate",
            flow_action_payload: { screen: "START", data: { source: "chat" } },
          },
        },
      },
    },
  ] satisfies OutgoingInteractive[];

  assertEquals(
    messages.map((message) => message.interactive.type),
    [
      "product",
      "product_list",
      "catalog_message",
      "location_request_message",
      "flow",
    ],
  );
});
