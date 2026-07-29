import { assertEquals, assertThrows } from "../_shared/test_assert.ts";
import {
  chatbotReplyPayloadSchema,
  parseChatbotReplyPayload,
  toOutgoingMessageContent,
} from "./payload.ts";

const basePayload = {
  phone_number_id: "15551234567",
  recipient: "923001234567",
  wamid: "wamid.reply-1",
  sent_at: "2026-07-29T12:30:00+00:00",
  chatbot: {
    key: "psdf",
    name: "PSDF",
  },
};

Deno.test("text reply payload normalizes tenant identifiers and content", () => {
  const payload = parseChatbotReplyPayload({
    ...basePayload,
    phone_number_id: " 15551234567 ",
    recipient: " 923001234567 ",
    chatbot: {
      key: " PSDF ",
      name: " PSDF Support ",
    },
    reply_to_wamid: "wamid.customer-1",
    message: {
      type: "text",
      text: { body: "Welcome to PSDF" },
    },
  });

  assertEquals(payload.phone_number_id, "15551234567");
  assertEquals(payload.recipient, "923001234567");
  assertEquals(payload.chatbot, {
    key: "psdf",
    name: "PSDF Support",
  });
  assertEquals(toOutgoingMessageContent(payload), {
    version: "1",
    re_message_id: "wamid.customer-1",
    type: "text",
    kind: "text",
    text: "Welcome to PSDF",
  });
});

Deno.test("button replies preserve stable IDs and titles", () => {
  const payload = parseChatbotReplyPayload({
    ...basePayload,
    message: {
      type: "interactive",
      interactive: {
        type: "button",
        body: { text: "Choose an option" },
        action: {
          buttons: [
            {
              type: "reply",
              reply: { id: "programs", title: "Programs" },
            },
            {
              type: "reply",
              reply: { id: "support", title: "Support" },
            },
          ],
        },
      },
    },
  });

  assertEquals(toOutgoingMessageContent(payload), {
    version: "1",
    type: "data",
    kind: "interactive",
    data: {
      type: "button",
      body: { text: "Choose an option" },
      action: {
        buttons: [
          {
            type: "reply",
            reply: { id: "programs", title: "Programs" },
          },
          {
            type: "reply",
            reply: { id: "support", title: "Support" },
          },
        ],
      },
    },
  });
});

Deno.test("list replies preserve sections, rows, and descriptions", () => {
  const payload = parseChatbotReplyPayload({
    ...basePayload,
    message: {
      type: "interactive",
      interactive: {
        type: "list",
        body: { text: "Choose a program" },
        action: {
          button: "View programs",
          sections: [
            {
              title: "Programs",
              rows: [
                {
                  id: "digital",
                  title: "Digital Skills",
                  description: "Technology courses",
                },
              ],
            },
          ],
        },
      },
    },
  });

  assertEquals(toOutgoingMessageContent(payload), {
    version: "1",
    type: "data",
    kind: "interactive",
    data: {
      type: "list",
      body: { text: "Choose a program" },
      action: {
        button: "View programs",
        sections: [
          {
            title: "Programs",
            rows: [
              {
                id: "digital",
                title: "Digital Skills",
                description: "Technology courses",
              },
            ],
          },
        ],
      },
    },
  });
});

Deno.test("unsupported future message types return a dedicated error", () => {
  for (const messageType of ["template", "image", "document"]) {
    assertThrows(
      () =>
        parseChatbotReplyPayload({
          ...basePayload,
          message: { type: messageType },
        }),
      `Unsupported message type: ${messageType}`,
    );
  }
});

Deno.test("payload rejects invalid WAMIDs, timestamps, and extra fields", () => {
  assertThrows(
    () =>
      chatbotReplyPayloadSchema.parse({
        ...basePayload,
        wamid: "reply-1",
        message: { type: "text", text: { body: "Hello" } },
      }),
    "wamid",
  );

  assertThrows(
    () =>
      chatbotReplyPayloadSchema.parse({
        ...basePayload,
        sent_at: "tomorrow",
        message: { type: "text", text: { body: "Hello" } },
      }),
    "sent_at",
  );

  assertThrows(
    () =>
      chatbotReplyPayloadSchema.parse({
        ...basePayload,
        organization_id: "14000000-0000-4000-8000-000000000001",
        message: { type: "text", text: { body: "Hello" } },
      }),
    "organization_id",
  );
});

Deno.test("interactive payloads enforce WhatsApp button and list limits", () => {
  assertThrows(
    () =>
      parseChatbotReplyPayload({
        ...basePayload,
        message: {
          type: "interactive",
          interactive: {
            type: "button",
            body: { text: "Choose" },
            action: {
              buttons: Array.from({ length: 4 }, (_, index) => ({
                type: "reply",
                reply: { id: `id-${index}`, title: `Option ${index}` },
              })),
            },
          },
        },
      }),
    "buttons",
  );

  assertThrows(
    () =>
      parseChatbotReplyPayload({
        ...basePayload,
        message: {
          type: "interactive",
          interactive: {
            type: "list",
            body: { text: "Choose" },
            action: {
              button: "Options",
              sections: [
                {
                  title: "First",
                  rows: Array.from({ length: 6 }, (_, index) => ({
                    id: `first-${index}`,
                    title: `First ${index}`,
                  })),
                },
                {
                  title: "Second",
                  rows: Array.from({ length: 5 }, (_, index) => ({
                    id: `second-${index}`,
                    title: `Second ${index}`,
                  })),
                },
              ],
            },
          },
        },
      }),
    "at most 10 rows",
  );
});
