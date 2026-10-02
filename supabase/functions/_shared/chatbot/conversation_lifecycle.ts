export function conversationLifecycleEnabled(organizationId: string): boolean {
  if (Deno.env.get("NODE_CONVERSATION_LIFECYCLE_ENABLED") !== "true") {
    return false;
  }
  const tenants =
    (Deno.env.get("NODE_CONVERSATION_LIFECYCLE_ORGANIZATIONS") ?? "").split(
      ",",
    );
  return tenants.includes("*") || tenants.includes(organizationId);
}

export function conversationOperationError(code: unknown): string {
  switch (code) {
    case "NEW_CUSTOMER_MESSAGE":
      return "A new customer message arrived—review it before closing.";
    case "OWNERSHIP_CHANGED":
      return "Conversation ownership changed. Refresh before trying again.";
    case "UNRESOLVED_OUTBOUND_SEND":
      return "Wait for pending messages to finish sending.";
    default:
      return "Node rejected the conversation action. Refresh and review its current state.";
  }
}
