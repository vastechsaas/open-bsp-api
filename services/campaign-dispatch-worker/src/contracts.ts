import { z } from "zod";

export const jobSchema = z.object({
  version: z.literal(1),
  job_id: z.string().uuid(),
  organization_id: z.string().uuid(),
  campaign_id: z.string().uuid(),
  delivery_id: z.string().uuid(),
}).strict();
export type Job = z.infer<typeof jobSchema>;
export const publicationSchema = jobSchema.extend({
  publication_token: z.string().uuid(),
  delay_ms: z.number().int().min(0).max(300_000),
});
export type Publication = z.infer<typeof publicationSchema>;
export type State = { phase: string; error_code?: string | null };

export function loadConfig(env: NodeJS.ProcessEnv) {
  const environment = z.enum(["staging", "production"]).parse(
    env.DEPLOYMENT_ENV,
  );
  const url = new URL(z.string().url().parse(env.SUPABASE_URL));
  const expected = environment === "staging"
    ? "acifbsuxmpdtlhbsvhlj"
    : "buvjopvpkgvzhykwsxnk";
  if (url.hostname !== `${expected}.supabase.co` || url.protocol !== "https:") {
    throw new Error("Supabase environment mismatch");
  }
  const broker = z.string().url().parse(env.CLOUDAMQP_URL);
  if (!broker.startsWith("amqps://")) {
    throw new Error("TLS broker URL required");
  }
  const serviceKey = z.string().min(20).parse(env.SUPABASE_SERVICE_ROLE_KEY);
  const dispatchKey = z.string().min(20).parse(
    env.EDGE_FUNCTIONS_TOKEN ?? serviceKey,
  );
  return {
    environment,
    url: url.origin,
    broker,
    serviceKey,
    dispatchKey,
    port: z.coerce.number().int().min(1).max(65535).default(8080).parse(
      env.PORT,
    ),
  };
}
