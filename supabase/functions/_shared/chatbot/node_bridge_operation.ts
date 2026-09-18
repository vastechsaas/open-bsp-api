/** Persist every returned state before its indicated remote action. */
export type BridgeOperationState = {
  request_id: string;
  attempts: number;
  status:
    | "pending"
    | "in_flight"
    | "reconciling"
    | "retry_wait"
    | "succeeded"
    | "failed";
  next_attempt_at: string | null;
  last_error: string | null;
};

export type BridgeRemoteResult =
  | { kind: "acknowledged" }
  | { kind: "ambiguous"; error: string }
  | { kind: "transient_failure"; error: string }
  | { kind: "permanent_failure"; error: string }
  | { kind: "confirmed_absent" };

export const BRIDGE_MAX_ATTEMPTS = 5;

export function beginBridgeAttempt(
  state: BridgeOperationState,
): BridgeOperationState {
  if (!["pending", "retry_wait"].includes(state.status)) {
    throw new Error(
      "Cannot submit an unresolved or completed bridge operation",
    );
  }
  if (state.attempts >= BRIDGE_MAX_ATTEMPTS) {
    throw new Error("Bridge retry limit reached");
  }
  return {
    ...state,
    attempts: state.attempts + 1,
    status: "in_flight",
    next_attempt_at: null,
  };
}

export function recordBridgeResult(
  state: BridgeOperationState,
  result: BridgeRemoteResult,
  now: number,
): BridgeOperationState {
  if (!["in_flight", "reconciling"].includes(state.status)) {
    throw new Error("Bridge result requires an outstanding attempt");
  }
  if (result.kind === "acknowledged") {
    return {
      ...state,
      status: "succeeded",
      next_attempt_at: null,
      last_error: null,
    };
  }
  if (result.kind === "ambiguous") {
    // Do not roll back, resubmit, or restore native execution after a timeout.
    return {
      ...state,
      status: "reconciling",
      last_error: result.error,
      next_attempt_at: new Date(now + 5000).toISOString(),
    };
  }
  if (result.kind === "confirmed_absent" && state.status !== "reconciling") {
    throw new Error("Absence must be confirmed by request-ID status lookup");
  }
  const error = "error" in result
    ? result.error
    : "Remote request confirmed absent";
  if (
    result.kind === "permanent_failure" || state.attempts >= BRIDGE_MAX_ATTEMPTS
  ) {
    return {
      ...state,
      status: "failed",
      last_error: error,
      next_attempt_at: null,
    };
  }
  return {
    ...state,
    status: "retry_wait",
    last_error: error,
    next_attempt_at: new Date(now + 1000 * 2 ** Math.max(0, state.attempts - 1))
      .toISOString(),
  };
}

/** Manual retry retains the logical request ID, including after exhaustion. */
export function manuallyRetryBridgeOperation(
  state: BridgeOperationState,
): BridgeOperationState {
  if (state.status !== "failed") {
    throw new Error("Only failed operations can be manually retried");
  }
  return {
    ...state,
    attempts: 0,
    status: "reconciling",
    next_attempt_at: null,
    last_error: state.last_error,
  };
}
