import { randomUUID } from "node:crypto";
import type { ConfirmChannel, ConsumeMessage, Options } from "amqplib";

export function createConfirmedPublisher(channel: ConfirmChannel) {
  const returned = new Set<string>();
  channel.on("return", (message: ConsumeMessage) => {
    if (typeof message.properties.correlationId === "string") {
      returned.add(message.properties.correlationId);
    }
  });
  return (
    queue: string,
    content: Buffer,
    properties: Options.Publish = {},
  ): Promise<void> =>
    new Promise((resolve, reject) => {
      const correlationId = randomUUID();
      const timer = setTimeout(() => {
        // A late confirmation is ambiguous. Close the session so the original
        // unacknowledged delivery is recovered with its stable event ID.
        void channel.close().catch(() => undefined);
        reject(new Error("publisher confirmation timeout"));
      }, 10_000);
      try {
        channel.sendToQueue(queue, content, {
          ...properties,
          persistent: true,
          mandatory: true,
          correlationId,
        }, (error: unknown) => {
          clearTimeout(timer);
          const unroutable = returned.delete(correlationId);
          if (error || unroutable) {
            reject(new Error("durable publication failed"));
          } else resolve();
        });
      } catch {
        clearTimeout(timer);
        reject(new Error("durable publication failed"));
      }
    });
}
export type PublishConfirmed = ReturnType<typeof createConfirmedPublisher>;
