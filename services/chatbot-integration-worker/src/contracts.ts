import { z } from "zod";

const digits = z.string().trim().regex(/^\d+$/).min(5).max(32);
const wamid = z.string().trim().regex(/^wamid\..+/).max(512);

const whatsappWebhookPayload = z.object({
  raw_body: z.string().min(2).max(2_000_000),
  x_hub_signature_256: z.string().regex(/^sha256=[a-fA-F0-9]{64}$/),
  app_id: digits,
}).strict().superRefine((payload, context) => {
  try {
    JSON.parse(payload.raw_body);
  } catch {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["raw_body"],
      message: "raw_body must contain valid JSON",
    });
  }
});

const textMessage = z.object({
  type: z.literal("text"),
  text: z.object({ body: z.string().min(1).max(4096) }).strict(),
}).strict();

const replyButton = z.object({
  type: z.literal("reply"),
  reply: z.object({
    id: z.string().trim().min(1).max(256),
    title: z.string().trim().min(1).max(20),
  }).strict(),
}).strict();

const interactiveButton = z.object({
  type: z.literal("button"),
  body: z.object({ text: z.string().min(1).max(1024) }).strict(),
  action: z.object({ buttons: z.array(replyButton).min(1).max(3) }).strict(),
}).strict();

const interactiveList = z.object({
  type: z.literal("list"),
  body: z.object({ text: z.string().min(1).max(1024) }).strict(),
  action: z.object({
    button: z.string().trim().min(1).max(20),
    sections: z.array(
      z.object({
        title: z.string().trim().min(1).max(24),
        rows: z.array(
          z.object({
            id: z.string().trim().min(1).max(200),
            title: z.string().trim().min(1).max(24),
            description: z.string().trim().min(1).max(72).optional(),
          }).strict(),
        ).min(1).max(10),
      }).strict(),
    ).min(1).max(10),
  }).strict(),
}).strict();

const interactiveContent = z.union([interactiveButton, interactiveList])
  .superRefine((value, context) => {
    if (
      value.type === "list" &&
      value.action.sections.reduce(
          (total, section) => total + section.rows.length,
          0,
        ) > 10
    ) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "WhatsApp list messages support at most 10 rows",
      });
    }
  });

const chatbotReplyPayload = z.object({
  phone_number_id: digits,
  recipient: digits,
  wamid,
  sent_at: z.string().datetime({ offset: true }),
  reply_to_wamid: wamid.optional(),
  message: z.discriminatedUnion("type", [
    textMessage,
    z.object({
      type: z.literal("interactive"),
      interactive: interactiveContent,
    }).strict(),
  ]),
}).strict();

const envelopeBase = {
  version: z.literal(1),
  event_id: z.string().uuid(),
  integration_key: z.string().trim().toLowerCase().regex(
    /^[a-z0-9][a-z0-9_-]{0,63}$/,
  ),
  occurred_at: z.string().datetime({ offset: true }),
};

export const integrationEventSchema = z.discriminatedUnion("event_type", [
  z.object({
    ...envelopeBase,
    event_type: z.literal("whatsapp_webhook"),
    payload: whatsappWebhookPayload,
  }).strict(),
  z.object({
    ...envelopeBase,
    event_type: z.literal("chatbot_reply"),
    payload: chatbotReplyPayload,
  }).strict(),
]);

export type IntegrationEvent = z.infer<typeof integrationEventSchema>;
export type ChatbotReplyEvent = Extract<
  IntegrationEvent,
  { event_type: "chatbot_reply" }
>;
export type WhatsAppWebhookEvent = Extract<
  IntegrationEvent,
  { event_type: "whatsapp_webhook" }
>;

export const accountConfigSchema = z.object({
  phone_number_id: digits,
  meta_app_id: digits,
  chatbot: z.object({
    key: z.string().trim().toLowerCase().regex(/^[a-z0-9][a-z0-9_-]{0,63}$/),
    name: z.string().trim().min(1).max(120),
  }).strict(),
  openbsp_api_key: z.string().min(1),
}).strict();

export type AccountConfig = z.infer<typeof accountConfigSchema>;
