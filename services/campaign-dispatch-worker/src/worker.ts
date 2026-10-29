import type { ConfirmChannel, ConsumeMessage } from "amqplib";
import { type Backend, BackendError } from "./backend.js";
import { jobSchema, type Publication } from "./contracts.js";
import type { Topology } from "./topology.js";

export async function publish(
  channel: ConfirmChannel,
  topology: Topology,
  route: string,
  body: Buffer,
  id: string,
  delay = 0,
) {
  let returned = false;
  const onReturn = (message: ConsumeMessage) => {
    if (message.properties.messageId === id) returned = true;
  };
  channel.on("return", onReturn);
  try {
    await new Promise<void>((resolve, reject) => {
      channel.publish(
        topology.exchange,
        route,
        body,
        {
          persistent: true,
          mandatory: true,
          contentType: "application/json",
          messageId: id,
          ...(delay > 0 ? { expiration: String(Math.ceil(delay)) } : {}),
        },
        (error) =>
          error
            ? reject(new Error("Broker confirm failed"))
            : returned
            ? reject(new Error("Unroutable publication"))
            : resolve(),
      );
    });
  } finally {
    channel.removeListener("return", onReturn);
  }
}

export async function publishJob(
  channel: ConfirmChannel,
  topology: Topology,
  backend: Backend,
  publication: Publication,
) {
  const { publication_token: _token, delay_ms: delay, ...job } = publication;
  await publish(
    channel,
    topology,
    delay > 0 ? "retry" : "dispatch",
    Buffer.from(JSON.stringify(job)),
    job.job_id,
    delay,
  );
  await backend.confirm(publication);
}

export function createConsumer(
  channel: ConfirmChannel,
  topology: Topology,
  backend: Backend,
  log: (event: string, fields?: Record<string, unknown>) => void,
) {
  return async (message: ConsumeMessage) => {
    let raw: unknown;
    try {
      raw = message.content.length <= 4096
        ? JSON.parse(message.content.toString("utf8"))
        : null;
    } catch {
      raw = null;
    }
    const parsed = jobSchema.safeParse(raw);
    if (!parsed.success) {
      // Never copy arbitrary malformed payloads/secrets into DLQ or logs.
      await publish(
        channel,
        topology,
        "dlq",
        Buffer.from(
          JSON.stringify({ version: 1, error_code: "invalid_envelope" }),
        ),
        "invalid-envelope",
      );
      channel.ack(message);
      return;
    }
    const job = parsed.data;
    let result;
    try {
      // Check identity before processing, including forged/stale queue envelopes.
      const existing = await backend.status(job);
      result = existing.phase === "pending"
        ? await backend.process(job)
        : existing;
    } catch (error) {
      if (
        error instanceof BackendError && [400, 403, 404].includes(error.status)
      ) {
        await publish(
          channel,
          topology,
          "dlq",
          Buffer.from(
            JSON.stringify({ ...job, error_code: "invalid_job_reference" }),
          ),
          job.job_id,
        );
        channel.ack(message);
        return;
      }
      // Reconcile the same durable job, not another send attempt.
      try {
        result = await backend.status(job);
      } catch {
        await publish(
          channel,
          topology,
          "retry",
          Buffer.from(JSON.stringify(job)),
          job.job_id,
          30_000,
        );
        channel.ack(message);
        return;
      }
    }
    if (["failed", "needs_review"].includes(result.phase)) {
      await publish(
        channel,
        topology,
        "dlq",
        Buffer.from(JSON.stringify({ ...job, error_code: result.phase })),
        job.job_id,
      );
    } else if (
      !["accepted", "retry_scheduled", "deferred"].includes(result.phase)
    ) {
      // Running/unknown state: DB recovery owns the lease. Revisit without resending.
      await publish(
        channel,
        topology,
        "retry",
        Buffer.from(JSON.stringify(job)),
        job.job_id,
        30_000,
      );
    }
    channel.ack(message);
    log("campaign_job_disposition", {
      job_id: job.job_id,
      phase: result.phase,
    });
  };
}
