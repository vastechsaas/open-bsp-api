import { z } from "zod";
import type { OutgoingMessage } from "../_shared/supabase.ts";

const digitsSchema = z.string().trim().regex(/^[0-9]+$/).min(5).max(32);
const identifierSchema = z.string().trim().min(1).max(512);
const wamidSchema = identifierSchema.refine(
  (value) => value.startsWith("wamid."),
  "Expected a WhatsApp message ID beginning with wamid.",
);

const textMessageSchema = z.object({
  type: z.literal("text"),
  text: z.object({
    body: z.string().min(1).max(4096),
  }).strict(),
}).strict();

const replyButtonSchema = z.object({
  type: z.literal("reply"),
  reply: z.object({
    id: z.string().trim().min(1).max(256),
    title: z.string().trim().min(1).max(20),
  }).strict(),
}).strict();

const interactiveButtonSchema = z.object({
  type: z.literal("button"),
  body: z.object({
    text: z.string().min(1).max(1024),
  }).strict(),
  action: z.object({
    buttons: z.array(replyButtonSchema).min(1).max(3),
  }).strict(),
}).strict();

const listRowSchema = z.object({
  id: z.string().trim().min(1).max(200),
  title: z.string().trim().min(1).max(24),
  description: z.string().trim().min(1).max(72).optional(),
}).strict();

const listSectionSchema = z.object({
  title: z.string().trim().min(1).max(24),
  rows: z.array(listRowSchema).min(1).max(10),
}).strict();

const interactiveListSchema = z.object({
  type: z.literal("list"),
  body: z.object({
    text: z.string().min(1).max(1024),
  }).strict(),
  action: z.object({
    button: z.string().trim().min(1).max(20),
    sections: z.array(listSectionSchema).min(1).max(10),
  }).strict(),
}).strict().refine(
  (interactive) =>
    interactive.action.sections.reduce(
      (count, section) => count + section.rows.length,
      0,
    ) <= 10,
  {
    message: "WhatsApp list messages support at most 10 rows",
    path: ["action", "sections"],
  },
);

const interactiveMessageSchema = z.object({
  type: z.literal("interactive"),
  interactive: z.discriminatedUnion("type", [
    interactiveButtonSchema,
    interactiveListSchema,
  ]),
}).strict();

export const chatbotReplyPayloadSchema = z.object({
  phone_number_id: digitsSchema,
  recipient: digitsSchema,
  wamid: wamidSchema.optional(),
  sent_at: z.string().datetime({ offset: true }),
  chatbot: z.object({
    key: z.string()
      .trim()
      .toLowerCase()
      .regex(/^[a-z0-9][a-z0-9_-]{0,63}$/),
    name: z.string().trim().min(1).max(120),
  }).strict(),
  reply_to_wamid: wamidSchema.optional(),
  message: z.discriminatedUnion("type", [
    textMessageSchema,
    interactiveMessageSchema,
  ]),
}).strict();

export type ChatbotReplyPayload = z.infer<typeof chatbotReplyPayloadSchema>;

export class UnsupportedMessageTypeError extends Error {
  constructor(readonly messageType: string) {
    super(`Unsupported message type: ${messageType}`);
    this.name = "UnsupportedMessageTypeError";
  }
}

export function resolveExternalReplyId(wamid?: string): string {
  return wamid ?? `wamid.openbsp.${crypto.randomUUID()}`;
}

export function parseChatbotReplyPayload(
  input: unknown,
): ChatbotReplyPayload {
  const messageType = input && typeof input === "object" &&
      "message" in input &&
      input.message &&
      typeof input.message === "object" &&
      "type" in input.message
    ? input.message.type
    : undefined;

  if (
    typeof messageType === "string" &&
    messageType !== "text" &&
    messageType !== "interactive"
  ) {
    throw new UnsupportedMessageTypeError(messageType);
  }

  return chatbotReplyPayloadSchema.parse(input);
}

export function toOutgoingMessageContent(
  payload: ChatbotReplyPayload,
): OutgoingMessage {
  const context = payload.reply_to_wamid
    ? { re_message_id: payload.reply_to_wamid }
    : {};

  if (payload.message.type === "text") {
    return {
      version: "1",
      ...context,
      type: "text",
      kind: "text",
      text: payload.message.text.body,
    };
  }

  return {
    version: "1",
    ...context,
    type: "data",
    kind: "interactive",
    data: payload.message.interactive,
  };
}
