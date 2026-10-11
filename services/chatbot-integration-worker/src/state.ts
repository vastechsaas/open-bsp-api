export type WorkerState = {
  connected: boolean;
  consuming: boolean;
  shuttingDown: boolean;
  inFlight: number;
  lanes: Record<
    "messages" | "statuses",
    { active: number; pending: number; consuming: boolean }
  >;
  routed: number;
  retried: number;
  processed: number;
  deadLettered: number;
  lastSuccessAt?: string;
  lastFailureAt?: string;
};

export function createWorkerState(): WorkerState {
  return {
    connected: false,
    consuming: false,
    shuttingDown: false,
    inFlight: 0,
    lanes: {
      messages: { active: 0, pending: 0, consuming: false },
      statuses: { active: 0, pending: 0, consuming: false },
    },
    routed: 0,
    retried: 0,
    processed: 0,
    deadLettered: 0,
  };
}
