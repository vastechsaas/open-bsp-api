import type { IntegrationEvent } from "./contracts.js";
import { eventLane, webhookValues } from "./routing.js";

// An optimization, never an authorization or persistence decision. Known local
// reply writes can settle before receipt work starts. After reconnect/timeout or
// unknown producers, the authenticated handler still checks the database and
// returns a durable-retry response if the original message is absent.
export class ReplyDependencies {
  private disposed = false;
  private pending = new Map<string, {
    ready: Promise<void>;
    release: () => void;
  }>();
  constructor(private readonly timeoutMs = 10_000) {}
  private key(
    integration: string,
    number: string,
    customer: string,
    id: string,
  ) {
    return JSON.stringify([integration, number, customer, id]);
  }
  reserve(event: IntegrationEvent) {
    if (this.disposed || event.event_type !== "chatbot_reply") return;
    const key = this.key(
      event.integration_key,
      event.payload.phone_number_id,
      event.payload.recipient,
      event.payload.wamid,
    );
    if (this.pending.has(key) || this.pending.size >= 10_000) return;
    let resolve!: () => void;
    const ready = new Promise<void>((done) => {
      resolve = done;
    });
    const timer = setTimeout(() => release(), this.timeoutMs);
    const release = () => {
      clearTimeout(timer);
      this.pending.delete(key);
      resolve();
    };
    this.pending.set(key, { ready, release });
  }
  complete(event: IntegrationEvent) {
    if (event.event_type !== "chatbot_reply") return;
    this.pending.get(
      this.key(
        event.integration_key,
        event.payload.phone_number_id,
        event.payload.recipient,
        event.payload.wamid,
      ),
    )?.release();
  }
  wait(event: IntegrationEvent): Promise<void> {
    if (
      event.event_type !== "whatsapp_webhook" || eventLane(event) !== "statuses"
    ) {
      return Promise.resolve();
    }
    const waits: Promise<void>[] = [];
    for (const value of webhookValues(event.payload.raw_body) ?? []) {
      const number =
        (value.metadata as { phone_number_id: string }).phone_number_id;
      for (
        const item of value.statuses as Array<
          { id: string; recipient_id: string }
        >
      ) {
        const pending = this.pending.get(
          this.key(event.integration_key, number, item.recipient_id, item.id),
        );
        if (pending) waits.push(pending.ready);
      }
    }
    return Promise.all(waits).then(() => undefined);
  }
  dispose() {
    this.disposed = true;
    for (const pending of this.pending.values()) pending.release();
  }
}
