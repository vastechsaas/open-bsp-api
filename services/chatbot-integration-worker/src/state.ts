export type WorkerState = {
  connected: boolean;
  consuming: boolean;
  shuttingDown: boolean;
  inFlight: boolean;
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
    inFlight: false,
    processed: 0,
    deadLettered: 0,
  };
}
