/** Computed from transport identity, never from flow/session/contact attributes. */
export const CHATBOT_SYSTEM_VARIABLES = [
  "customer_phone",
  "conversation_id",
] as const;

export function isChatbotSystemVariable(name: string): boolean {
  return (CHATBOT_SYSTEM_VARIABLES as readonly string[]).includes(name);
}

/** WhatsApp supplies international digits; do not guess a country or use a profile field. */
export function normalizeCustomerPhone(sender: unknown): string | undefined {
  if (typeof sender !== "string") return undefined;
  const value = sender.trim();
  return /^\+?[1-9]\d{1,14}$/.test(value)
    ? `+${value.replace(/^\+/, "")}`
    : undefined;
}

/** Supplied by the runtime, not by editable session data or API responses. */
export function normalizeConversationId(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  return /^[1-9]\d{0,19}$/.test(value) ||
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        value,
      )
    ? value
    : undefined;
}

export function writableChatbotVariables<T>(
  variables: Readonly<Record<string, T>>,
): Record<string, T> {
  return Object.fromEntries(
    Object.entries(variables).filter(([name]) =>
      !isChatbotSystemVariable(name)
    ),
  );
}
