type Ownership = {
  revision?: string;
  human_owned?: boolean;
  ownership_revision?: string;
  lifecycle_enabled?: boolean;
  state?: string;
  support_request?: { id?: string; status?: string } | null;
};

// Node's live snapshot can overtake its queue event. Never offer a reservation
// until the local row used by begin_node_conversation_operation agrees.
export function takeoverSynchronizationPending(
  mapping: Ownership,
  snapshot: Ownership,
) {
  if (snapshot.support_request?.status !== "waiting") return false;
  return !mapping.lifecycle_enabled || mapping.human_owned !== false ||
    mapping.ownership_revision !== snapshot.revision ||
    mapping.support_request?.id !== snapshot.support_request.id ||
    mapping.support_request?.status !== "waiting";
}

export function conversationReservationError(message: string) {
  const codes: Record<string, string> = {
    "conversation ownership changed": "OWNERSHIP_CHANGED",
    "conversation is not in active human support": "SUPPORT_STATE_CHANGED",
    "conversation has an unresolved bridge operation": "OPERATION_PENDING",
    "Wait for pending human messages to finish sending.": "HUMAN_SEND_PENDING",
    "request ID cannot be reused with different data": "REQUEST_ID_REUSE",
    "A new customer message arrived—review it before closing.":
      "NEW_CUSTOMER_MESSAGE",
  };
  return codes[message] ?? "CONVERSATION_ACTION_REJECTED";
}
