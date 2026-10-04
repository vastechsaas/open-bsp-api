import { assertEquals } from "../test_assert.ts";
import {
  conversationReservationError,
  takeoverSynchronizationPending,
} from "./takeover_readiness.ts";

const waiting = { id: "support-1", status: "waiting" };
const mapping = {
  lifecycle_enabled: true,
  human_owned: false,
  ownership_revision: "10",
  support_request: waiting,
};
const snapshot = {
  revision: "10",
  state: "bot_ready",
  support_request: waiting,
};

Deno.test("takeover waits for the matching support event and ownership revision", () => {
  assertEquals(takeoverSynchronizationPending(mapping, snapshot), false);
  for (
    const changed of [
      { ...mapping, lifecycle_enabled: false },
      { ...mapping, human_owned: true },
      { ...mapping, ownership_revision: "9" },
      { ...mapping, ownership_revision: "11" },
      { ...mapping, support_request: null },
      { ...mapping, support_request: { id: "old", status: "waiting" } },
      { ...mapping, support_request: { ...waiting, status: "handling" } },
    ]
  ) assertEquals(takeoverSynchronizationPending(changed, snapshot), true);
});

Deno.test("ordinary inbound messages do not change takeover readiness; handled chats never show sync waiting", () => {
  assertEquals(
    takeoverSynchronizationPending(mapping, {
      ...snapshot,
      state: "bot_active",
    }),
    false,
  );
  assertEquals(
    takeoverSynchronizationPending(mapping, {
      revision: "11",
      state: "human_owned",
      support_request: { ...waiting, status: "handling" },
    }),
    false,
  );
});

Deno.test("reservation errors distinguish safe refresh from competing operations and send guards", () => {
  assertEquals(
    conversationReservationError("conversation ownership changed"),
    "OWNERSHIP_CHANGED",
  );
  assertEquals(
    conversationReservationError("conversation is not in active human support"),
    "SUPPORT_STATE_CHANGED",
  );
  assertEquals(
    conversationReservationError(
      "conversation has an unresolved bridge operation",
    ),
    "OPERATION_PENDING",
  );
  assertEquals(
    conversationReservationError(
      "Wait for pending human messages to finish sending.",
    ),
    "HUMAN_SEND_PENDING",
  );
  assertEquals(
    conversationReservationError("unknown"),
    "CONVERSATION_ACTION_REJECTED",
  );
});
