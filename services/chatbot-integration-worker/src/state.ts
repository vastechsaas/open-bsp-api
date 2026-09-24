export type WorkerState = {
  connected: boolean;
  consuming: boolean;
  shuttingDown: boolean;
  inFlight: number;
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
    processed: 0,
    deadLettered: 0,
  };
}
