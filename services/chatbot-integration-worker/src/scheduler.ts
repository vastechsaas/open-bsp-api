import { conflicts, type Reservation } from "./routing.js";

type Job = {
  reservation: Reservation;
  run: () => Promise<void>;
  resolve: () => void;
  reject: (error: unknown) => void;
};
export class Scheduler {
  private waiting: Job[] = [];
  private active = new Set<Job>();
  private stopped = false;
  constructor(
    private readonly limit: number,
    private readonly changed: (active: number, pending: number) => void =
      () => {},
  ) {}
  enqueue(reservation: Reservation, run: () => Promise<void>): Promise<void> {
    if (this.stopped) return Promise.reject(new Error("scheduler stopped"));
    return new Promise<void>((resolve, reject) => {
      this.waiting.push({ reservation, run, resolve, reject });
      this.pump();
    });
  }
  stop() {
    this.stopped = true;
    for (const job of this.waiting.splice(0)) {
      job.reject(new Error("scheduler stopped"));
    }
    this.report();
  }
  private report() {
    this.changed(this.active.size, this.waiting.length);
  }
  private pump() {
    if (this.stopped) return;
    for (
      let index = 0;
      index < this.waiting.length && this.active.size < this.limit;
    ) {
      const job = this.waiting[index]!;
      if (
        [...this.active, ...this.waiting.slice(0, index)].some((prior) =>
          conflicts(prior.reservation, job.reservation)
        )
      ) {
        index++;
        continue;
      }
      this.waiting.splice(index, 1);
      this.active.add(job);
      void Promise.resolve().then(job.run).then(job.resolve, job.reject)
        .finally(() => {
          this.active.delete(job);
          this.report();
          this.pump();
        });
    }
    this.report();
  }
}
