export type DispatchJob = {
  id: string;
  organization_id: string;
  campaign_id: string;
  delivery_id: string;
  phase: string;
  error_code: string | null;
  external_id: string | null;
};

export type DispatchRepository = {
  status(id: string): Promise<DispatchJob | null>;
  claim(id: string): Promise<{ phase: string; lease_token?: string } | null>;
  begin(id: string, token: string): Promise<boolean>;
  finish(
    id: string,
    token: string,
    outcome: string,
    externalId?: string,
    code?: string,
  ): Promise<string>;
};

export type DispatchDependencies<T> = {
  repository: DispatchRepository;
  serviceKey: string;
  prepare(job: DispatchJob): Promise<T>;
  send(prepared: T): Promise<{ messages?: Array<{ id?: string }> }>;
  classify(
    error: unknown,
  ): { retryable: boolean; definitive: boolean; code: string };
};

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const response = (body: unknown, status = 200) =>
  Response.json(body, { status });

export function createDispatchHandler<T>(deps: DispatchDependencies<T>) {
  return async (req: Request): Promise<Response> => {
    if (
      !deps.serviceKey ||
      req.headers.get("Authorization") !== `Bearer ${deps.serviceKey}`
    ) {
      return response({ error: "Unauthorized" }, 401);
    }
    if (!["GET", "POST"].includes(req.method)) {
      return response({ error: "Method not allowed" }, 405);
    }
    const id = new URL(req.url).pathname.match(/\/jobs\/([^/]+)$/)?.[1];
    if (!id || !uuid.test(id)) {
      return response({ error: "Invalid job ID" }, 400);
    }
    try {
      const job = await deps.repository.status(id);
      if (!job) return response({ error: "Job not found" }, 404);
      if (req.method === "GET") return response(job);
      const input = await req.json().catch(() => null);
      if (
        !input || input.version !== 1 || input.job_id !== job.id ||
        input.organization_id !== job.organization_id ||
        input.campaign_id !== job.campaign_id ||
        input.delivery_id !== job.delivery_id || Object.keys(input).length !== 5
      ) {
        return response({ error: "Job identity mismatch" }, 400);
      }
      const claim = await deps.repository.claim(id);
      if (!claim || claim.phase !== "claimed" || !claim.lease_token) {
        return response(claim);
      }
      const token = claim.lease_token;
      let submitted = false;
      let externalId: string | undefined;
      try {
        const prepared = await deps.prepare(job);
        if (!await deps.repository.begin(id, token)) {
          // No external call happened. A stale preparer must never send.
          return response({ phase: "reconciling" });
        }
        submitted = true;
        const sent = await deps.send(prepared);
        externalId = sent.messages?.[0]?.id;
        if (!externalId) {
          const phase = await deps.repository.finish(
            id,
            token,
            "needs_review",
            undefined,
            "missing_meta_message_id",
          );
          return response({ phase });
        }
        const phase = await deps.repository.finish(
          id,
          token,
          "accepted",
          externalId,
        );
        return response({ phase });
      } catch (error) {
        if (externalId) {
          // Retry the durable write, never the external send.
          const phase = await deps.repository.finish(
            id,
            token,
            "accepted",
            externalId,
          );
          return response({ phase });
        }
        const detail = deps.classify(error);
        const outcome = submitted && !detail.definitive
          ? "needs_review"
          : detail.retryable
          ? "retry"
          : "failed";
        const phase = await deps.repository.finish(
          id,
          token,
          outcome,
          undefined,
          detail.code,
        );
        return response({ phase });
      }
    } catch {
      // No raw provider responses, credentials, contacts or payloads in errors/logs.
      return response({
        error: "Dispatch state unavailable; reconcile job status",
        job_id: id,
      }, 503);
    }
  };
}
