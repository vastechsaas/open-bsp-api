import {
  beginBridgeAttempt,
  type BridgeOperationState,
  manuallyRetryBridgeOperation,
  recordBridgeResult,
} from "./node_bridge_operation.ts";

function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
const initial = (): BridgeOperationState => ({
  request_id: "11111111-1111-4111-8111-111111111111",
  attempts: 0,
  status: "pending",
  next_attempt_at: null,
  last_error: null,
});

Deno.test("bridge operation: five bounded exponential retries retain request ID", () => {
  let state = initial();
  for (let attempt = 1; attempt <= 5; attempt++) {
    state = beginBridgeAttempt(state);
    state = recordBridgeResult(state, {
      kind: "transient_failure",
      error: "unavailable",
    }, 0);
    assert(
      state.attempts === attempt && state.request_id === initial().request_id,
    );
    if (attempt < 5) {
      assert(Date.parse(state.next_attempt_at!) === 1000 * 2 ** (attempt - 1));
    }
  }
  assert(state.status === "failed" && state.next_attempt_at === null);
});

Deno.test("bridge operation: ambiguous timeout requires reconciliation, not another submit", () => {
  const state = recordBridgeResult(beginBridgeAttempt(initial()), {
    kind: "ambiguous",
    error: "timeout",
  }, 0);
  assert(state.status === "reconciling");
  let rejected = false;
  try {
    beginBridgeAttempt(state);
  } catch {
    rejected = true;
  }
  assert(rejected);
  const acknowledged = recordBridgeResult(state, { kind: "acknowledged" }, 0);
  assert(acknowledged.status === "succeeded" && acknowledged.attempts === 1);
  const absent = recordBridgeResult(state, { kind: "confirmed_absent" }, 0);
  assert(absent.status === "retry_wait");
});

Deno.test("bridge operation: permanent errors and manual retries never claim success", () => {
  const failed = recordBridgeResult(beginBridgeAttempt(initial()), {
    kind: "permanent_failure",
    error: "wrong number",
  }, 0);
  assert(failed.status === "failed");
  const retried = manuallyRetryBridgeOperation(failed);
  assert(
    retried.status === "reconciling" &&
      retried.request_id === failed.request_id,
  );
  const exhausted = manuallyRetryBridgeOperation({ ...failed, attempts: 5 });
  const absent = recordBridgeResult(exhausted, { kind: "confirmed_absent" }, 0);
  assert(beginBridgeAttempt(absent).attempts === 1);
});
