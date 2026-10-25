import { HTTPException } from "jsr:@hono/hono/http-exception";

export type IntegrationAvailabilityClient = {
  rpc(name: "is_integration_available", args: {
    p_organization_id: string;
    p_integration_id: string;
  }): PromiseLike<{ data: boolean | null; error: unknown }>;
};

/** Call once after authorization/token validation, before the first external
 * effect. Accepted work may finish if availability changes during registration.
 * Never use this guard for dispatch, maintenance or disconnect callbacks. */
export async function requireIntegrationAvailable(
  client: IntegrationAvailabilityClient,
  organizationId: string,
  integrationId: "whatsapp" | "instagram",
) {
  const { data, error } = await client.rpc("is_integration_available", {
    p_organization_id: organizationId,
    p_integration_id: integrationId,
  });
  if (error) {
    throw new HTTPException(503, {
      message: "Integration availability could not be checked",
    });
  }
  if (data !== true) {
    throw new HTTPException(403, {
      message: "This integration is unavailable for this organization",
      cause: { code: "INTEGRATION_UNAVAILABLE" },
    });
  }
}
