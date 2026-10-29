import type { Job, Publication, State } from "./contracts.js";
import { publicationSchema } from "./contracts.js";
import { z } from "zod";

export type Backend = {
  publications(): Promise<Publication[]>;
  confirm(job: Publication): Promise<void>;
  recover(): Promise<void>;
  process(job: Job): Promise<State>;
  status(job: Job): Promise<State>;
};
export class BackendError extends Error {
  constructor(readonly status: number) {
    super("Backend request unavailable");
  }
}

export function createBackend(
  url: string,
  key: string,
  fetcher: typeof fetch = fetch,
  dispatchKey: string = key,
): Backend {
  async function request(path: string, body?: unknown) {
    const response = await fetcher(`${url}${path}`, {
      method: body === undefined ? "GET" : "POST",
      headers: {
        Authorization: `Bearer ${
          path.startsWith("/functions/") ? dispatchKey : key
        }`,
        apikey: key,
        "Content-Type": "application/json",
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(25_000),
    });
    if (!response.ok) throw new BackendError(response.status);
    return response.json() as Promise<unknown>;
  }
  const rpc = (name: string, body: unknown = {}) =>
    request(`/rest/v1/rpc/${name}`, body);
  const state = (data: unknown) =>
    z.object({
      phase: z.string(),
      error_code: z.string().nullable().optional(),
    }).parse(data);
  return {
    publications: async () =>
      z.array(publicationSchema).parse(
        await rpc("claim_campaign_dispatch_publications", { p_limit: 25 }),
      ),
    confirm: async (job) => {
      await rpc("confirm_campaign_dispatch_publication", {
        p_job_id: job.job_id,
        p_token: job.publication_token,
      });
    },
    recover: async () => {
      await rpc("recover_campaign_dispatch_jobs");
    },
    process: async (job) =>
      state(
        await request(
          `/functions/v1/campaign-dispatch/jobs/${job.job_id}`,
          job,
        ),
      ),
    status: async (job) => {
      const data = await request(
        `/functions/v1/campaign-dispatch/jobs/${job.job_id}`,
      );
      const identity = z.object({
        id: z.string(),
        organization_id: z.string(),
        campaign_id: z.string(),
        delivery_id: z.string(),
      }).parse(data);
      if (
        identity.id !== job.job_id ||
        identity.organization_id !== job.organization_id ||
        identity.campaign_id !== job.campaign_id ||
        identity.delivery_id !== job.delivery_id
      ) throw new BackendError(400);
      return state(data);
    },
  };
}
